//
//  GSChunkVoxelData.m
//  GutsyStorm
//
//  Created by Andrew Fox on 4/17/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import "GSChunkVoxelData.h"
#import "GSChunkStore.h"
#import "GSBoxedVector.h"


@interface GSChunkVoxelData (Private)

- (void)destroyVoxelData;
- (void)allocateVoxelData;
- (void)loadVoxelDataFromFile:(NSURL *)url;
- (void)generateVoxelDataWithCallback:(terrain_generator_t)callback;
- (void)recalcOutsideVoxelsNoLock;
- (void)saveVoxelDataToFile;
- (BOOL)isAdjacentToSunlightAtPoint:(GSIntegerVector3)p lightLevel:(int)lightLevel;
- (void)clearSunlightBuffer;
- (void)computeHardLocalSunlight;
- (void)generateSunlightWithNeighbors:(GSNeighborhood *)neighbors;

@end


@implementation GSChunkVoxelData

+ (NSString *)fileNameForVoxelDataFromMinP:(GSVector3)minP
{
    return [NSString stringWithFormat:@"%.0f_%.0f_%.0f.voxels.dat", minP.x, minP.y, minP.z];
}


- (id)initWithMinP:(GSVector3)_minP
            folder:(NSURL *)_folder
    groupForSaving:(dispatch_group_t)_groupForSaving
    chunkTaskQueue:(dispatch_queue_t)_chunkTaskQueue
         generator:(terrain_generator_t)callback
{
    self = [super initWithMinP:_minP];
    if (self) {
        groupForSaving = _groupForSaving; // dispatch group used for tasks related to saving chunks to disk
        dispatch_retain(groupForSaving);
        
        chunkTaskQueue = _chunkTaskQueue; // dispatch queue used for chunk background work
        dispatch_retain(_chunkTaskQueue);
        
        folder = _folder;
        [folder retain];
        
        lockVoxelData = [[GSReaderWriterLock alloc] init];
        [lockVoxelData lockForWriting]; // This is locked initially and unlocked at the end of the first update.
        
        lockSunlight = [[GSReaderWriterLock alloc] init];
        [lockSunlight lockForWriting]; // This is locked initially and unlocked at the end of the first update.
        
        voxelData = NULL;
        sunlight = NULL;
        
        // Fire off asynchronous task to generate voxel data.
        dispatch_async(chunkTaskQueue, ^{
            NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForVoxelDataFromMinP:minP]
                                relativeToURL:folder];
            
            [self allocateVoxelData];
            
            if([url checkResourceIsReachableAndReturnError:NULL]) {
                // Load chunk from disk.
                [self loadVoxelDataFromFile:url];
            } else {
                // Generate chunk from scratch.
                [self generateVoxelDataWithCallback:callback];
                [self saveVoxelDataToFile];
            }
            
            [self recalcOutsideVoxelsNoLock];
            
            [lockVoxelData unlockForWriting];
            
            // And now generate sunlight for this chunk.
            [self clearSunlightBuffer];
            [self computeHardLocalSunlight];
            [lockSunlight unlockForWriting];
        });
    }
    
    return self;
}


- (void)dealloc
{
    dispatch_release(groupForSaving);
    dispatch_release(chunkTaskQueue);
    [folder release];
    
    [lockVoxelData lockForWriting];
    [self destroyVoxelData];
    [lockVoxelData unlockForWriting];
    [lockVoxelData release];
    
    [lockSunlight lockForWriting];
    free(sunlight);
    sunlight = NULL;
    [lockSunlight unlockForWriting];
    [lockSunlight release];
    
    [super dealloc];
}


// Assumes the caller is already holding "lockVoxelData".
- (voxel_t)getVoxelAtPoint:(GSIntegerVector3)p
{
    return *[self getPointerToVoxelAtPoint:p];
}


// Assumes the caller is already holding "lockVoxelData".
- (voxel_t *)getPointerToVoxelAtPoint:(GSIntegerVector3)p
{
    assert(voxelData);
    assert(p.x >= 0 && p.x < CHUNK_SIZE_X);
    assert(p.y >= 0 && p.y < CHUNK_SIZE_Y);
    assert(p.z >= 0 && p.z < CHUNK_SIZE_Z);
    
    size_t idx = INDEX(p.x, p.y, p.z);
    assert(idx >= 0 && idx < (CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z));
    
    return &voxelData[idx];
}


- (uint8_t)getSunlightAtPoint:(GSIntegerVector3)p
{
    return *[self getPointerToSunlightAtPoint:p];
}


- (uint8_t *)getPointerToSunlightAtPoint:(GSIntegerVector3)p
{
    assert(sunlight);
    assert(p.x >= 0 && p.x < CHUNK_SIZE_X);
    assert(p.y >= 0 && p.y < CHUNK_SIZE_Y);
    assert(p.z >= 0 && p.z < CHUNK_SIZE_Z);
    
    size_t idx = INDEX(p.x, p.y, p.z);
    assert(idx >= 0 && idx < (CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z));
    
    return &sunlight[idx];
}


- (void)updateLightingWithNeighbors:(GSNeighborhood *)n doItSynchronously:(BOOL)sync
{
    void (^b)(void) = ^{
        [n readerAccessToVoxelDataUsingBlock:^{
            [n writerAccessToSunlightDataUsingBlock:^{
                [self generateSunlightWithNeighbors:n];
            }];
        }];
    };
    
    if(sync) {
        b();
    } else {
        dispatch_async(chunkTaskQueue, b);
    }
}


// Assumes the caller is already holding "lockSunlight" on all neighbors and "lockVoxelData" on self, at least.
- (void)interpolateSunlightAtPoint:(GSIntegerVector3)p
                       neighbors:(GSNeighborhood *)neighbors
                     outLighting:(block_lighting_t *)lighting
{
    /* Front is in the -Z direction and back is the +Z direction.
     * This is a totally arbitrary convention.
     */
    
    // If the block is empty then bail out early. The point p is always within the chunk.
    if(isVoxelEmpty(voxelData[INDEX(p.x, p.y, p.z)])) {
        block_lighting_vertex_t packed = packBlockLightingValuesForVertex(CHUNK_LIGHTING_MAX,
                                                                          CHUNK_LIGHTING_MAX,
                                                                          CHUNK_LIGHTING_MAX,
                                                                          CHUNK_LIGHTING_MAX);
        
        lighting->top = packed;
        lighting->bottom = packed;
        lighting->left = packed;
        lighting->right = packed;
        lighting->front = packed;
        lighting->back = packed;
        return;
    }
    
#define SUNLIGHT(x, y, z) (samples[(x+1)*3*3 + (y+1)*3 + (z+1)])
    
    unsigned samples[3*3*3];
    
    for(ssize_t x = -1; x <= 1; ++x)
    {
        for(ssize_t y = -1; y <= 1; ++y)
        {
            for(ssize_t z = -1; z <= 1; ++z)
            {
                SUNLIGHT(x, y, z) = [neighbors getBlockSunlightAtPoint:GSIntegerVector3_Make(p.x + x, p.y + y, p.z + z)];
            }
        }
    }
    
    lighting->top = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT( 0, 1,  0),
                                                                 SUNLIGHT( 0, 1, -1),
                                                                 SUNLIGHT(-1, 1,  0),
                                                                 SUNLIGHT(-1, 1, -1)),
                                                     avgSunlight(SUNLIGHT( 0, 1,  0),
                                                                 SUNLIGHT( 0, 1, +1),
                                                                 SUNLIGHT(-1, 1,  0),
                                                                 SUNLIGHT(-1, 1, +1)),
                                                     avgSunlight(SUNLIGHT( 0, 1,  0),
                                                                 SUNLIGHT( 0, 1, +1),
                                                                 SUNLIGHT(+1, 1,  0),
                                                                 SUNLIGHT(+1, 1, +1)),
                                                     avgSunlight(SUNLIGHT( 0, 1,  0),
                                                                 SUNLIGHT( 0, 1, -1),
                                                                 SUNLIGHT(+1, 1,  0),
                                                                 SUNLIGHT(+1, 1, -1)));
    
    lighting->bottom = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT( 0, -1,  0),
                                                                    SUNLIGHT( 0, -1, -1),
                                                                    SUNLIGHT(-1, -1,  0),
                                                                    SUNLIGHT(-1, -1, -1)),
                                                        avgSunlight(SUNLIGHT( 0, -1,  0),
                                                                    SUNLIGHT( 0, -1, -1),
                                                                    SUNLIGHT(+1, -1,  0),
                                                                    SUNLIGHT(+1, -1, -1)),
                                                        avgSunlight(SUNLIGHT( 0, -1,  0),
                                                                    SUNLIGHT( 0, -1, +1),
                                                                    SUNLIGHT(+1, -1,  0),
                                                                    SUNLIGHT(+1, -1, +1)),
                                                        avgSunlight(SUNLIGHT( 0, -1,  0),
                                                                    SUNLIGHT( 0, -1, +1),
                                                                    SUNLIGHT(-1, -1,  0),
                                                                    SUNLIGHT(-1, -1, +1)));
    
    lighting->back = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT( 0, -1, 1),
                                                                  SUNLIGHT( 0,  0, 1),
                                                                  SUNLIGHT(-1, -1, 1),
                                                                  SUNLIGHT(-1,  0, 1)),
                                                      avgSunlight(SUNLIGHT( 0, -1, 1),
                                                                  SUNLIGHT( 0,  0, 1),
                                                                  SUNLIGHT(+1, -1, 1),
                                                                  SUNLIGHT(+1,  0, 1)),
                                                      avgSunlight(SUNLIGHT( 0, +1, 1),
                                                                  SUNLIGHT( 0,  0, 1),
                                                                  SUNLIGHT(+1, +1, 1),
                                                                  SUNLIGHT(+1,  0, 1)),
                                                      avgSunlight(SUNLIGHT( 0, +1, 1),
                                                                  SUNLIGHT( 0,  0, 1),
                                                                  SUNLIGHT(-1, +1, 1),
                                                                  SUNLIGHT(-1,  0, 1)));
    
    lighting->front = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT( 0, -1, -1),
                                                                   SUNLIGHT( 0,  0, -1),
                                                                   SUNLIGHT(-1, -1, -1),
                                                                   SUNLIGHT(-1,  0, -1)),
                                                       avgSunlight(SUNLIGHT( 0, +1, -1),
                                                                   SUNLIGHT( 0,  0, -1),
                                                                   SUNLIGHT(-1, +1, -1),
                                                                   SUNLIGHT(-1,  0, -1)),
                                                       avgSunlight(SUNLIGHT( 0, +1, -1),
                                                                   SUNLIGHT( 0,  0, -1),
                                                                   SUNLIGHT(+1, +1, -1),
                                                                   SUNLIGHT(+1,  0, -1)),
                                                       avgSunlight(SUNLIGHT( 0, -1, -1),
                                                                   SUNLIGHT( 0,  0, -1),
                                                                   SUNLIGHT(+1, -1, -1),
                                                                   SUNLIGHT(+1,  0, -1)));
    
    lighting->right = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT(+1,  0,  0),
                                                                   SUNLIGHT(+1,  0, -1),
                                                                   SUNLIGHT(+1, -1,  0),
                                                                   SUNLIGHT(+1, -1, -1)),
                                                       avgSunlight(SUNLIGHT(+1,  0,  0),
                                                                   SUNLIGHT(+1,  0, -1),
                                                                   SUNLIGHT(+1, +1,  0),
                                                                   SUNLIGHT(+1, +1, -1)),
                                                       avgSunlight(SUNLIGHT(+1,  0,  0),
                                                                   SUNLIGHT(+1,  0, +1),
                                                                   SUNLIGHT(+1, +1,  0),
                                                                   SUNLIGHT(+1, +1, +1)),
                                                       avgSunlight(SUNLIGHT(+1,  0,  0),
                                                                   SUNLIGHT(+1,  0, +1),
                                                                   SUNLIGHT(+1, -1,  0),
                                                                   SUNLIGHT(+1, -1, +1)));
    
    lighting->left = packBlockLightingValuesForVertex(avgSunlight(SUNLIGHT(-1,  0,  0),
                                                                  SUNLIGHT(-1,  0, -1),
                                                                  SUNLIGHT(-1, -1,  0),
                                                                  SUNLIGHT(-1, -1, -1)),
                                                      avgSunlight(SUNLIGHT(-1,  0,  0),
                                                                  SUNLIGHT(-1,  0, +1),
                                                                  SUNLIGHT(-1, -1,  0),
                                                                  SUNLIGHT(-1, -1, +1)),
                                                      avgSunlight(SUNLIGHT(-1,  0,  0),
                                                                  SUNLIGHT(-1,  0, +1),
                                                                  SUNLIGHT(-1, +1,  0),
                                                                  SUNLIGHT(-1, +1, +1)),
                                                      avgSunlight(SUNLIGHT(-1,  0,  0),
                                                                  SUNLIGHT(-1,  0, -1),
                                                                  SUNLIGHT(-1, +1,  0),
                                                                  SUNLIGHT(-1, +1, -1)));
    
#undef SUNLIGHT
}


- (void)markAsDirtyAndSpinOffSavingTask
{
    // Mark as dirty
    [lockVoxelData lockForWriting];
    dirty = YES;
    [lockVoxelData unlockForWriting];
    
    /* Spin off a task to save the chunk. (Marks as clean when complete.)
     * This is latency sensitive, so submit to the global queue. Do not use `chunkTaskQueue' as that would cause the block to be
     * added to the end of a long queue of basically serialized background tasks.
     */
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_async(groupForSaving, queue, ^{
        [lockVoxelData lockForWriting];
        [self saveVoxelDataToFile];
        [lockVoxelData unlockForWriting];
    });
}


- (void)readerAccessToVoxelDataUsingBlock:(void (^)(void))block
{
    [lockVoxelData lockForReading];
    block();
    [lockVoxelData unlockForReading];
}


- (void)writerAccessToVoxelDataUsingBlock:(void (^)(void))block
{
    [lockVoxelData lockForWriting];
    block();
    [lockVoxelData unlockForWriting];
}


- (GSReaderWriterLock *)getVoxelDataLock
{
    return lockVoxelData;
}


- (void)readerAccessToSunlightDataUsingBlock:(void (^)(void))block
{
    [lockSunlight lockForReading];
    block();
    [lockSunlight unlockForReading];
}


- (void)writerAccessToSunlightDataUsingBlock:(void (^)(void))block
{
    [lockSunlight lockForWriting];
    block();
    [lockSunlight unlockForWriting];
}


- (GSReaderWriterLock *)getSunlightDataLock
{
    return lockSunlight;
}

@end


@implementation GSChunkVoxelData (Private)

// Assumes the caller is already holding "lockVoxelData" for writing. ("writing" so we can protect `dirty')
- (void)saveVoxelDataToFile
{
    if(!dirty) {
        return;
    }
    
    const size_t len = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t);
    
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForVoxelDataFromMinP:minP]
                        relativeToURL:folder];
    
    [[NSData dataWithBytes:voxelData length:len] writeToURL:url atomically:YES];
    
    dirty = YES;
}


// Assumes the caller is already holding "lockVoxelData".
- (void)allocateVoxelData
{
    [self destroyVoxelData];
    
    voxelData = malloc(CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t));
    if(!voxelData) {
        [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for chunk's voxelData"];
    }
}


// Assumes the caller is already holding "lockVoxelData".
- (void)destroyVoxelData
{
    free(voxelData);
    voxelData = NULL;
}


// Assumes the caller is already holding "lockVoxelData".
- (void)recalcOutsideVoxelsNoLock
{
    // Determine voxels in the chunk which are outside. That is, voxels which are directly exposed to the sky from above.
    // We assume here that the chunk is the height of the world.
    for(ssize_t x = 0; x < CHUNK_SIZE_X; ++x)
    {
        for(ssize_t z = 0; z < CHUNK_SIZE_Z; ++z)
        {
            // Get the y value of the highest non-empty voxel in the chunk.
            ssize_t heightOfHighestVoxel;
            for(heightOfHighestVoxel = CHUNK_SIZE_Y-1; heightOfHighestVoxel >= 0; --heightOfHighestVoxel)
            {
                GSIntegerVector3 p = {x, heightOfHighestVoxel, z};
                voxel_t *voxel = [self getPointerToVoxelAtPoint:p];
                
                if(!isVoxelEmpty(*voxel)) {
                    break;
                }
            }
            
            for(ssize_t y = 0; y < CHUNK_SIZE_Y; ++y)
            {
                GSIntegerVector3 p = {x, y, z};
                voxel_t *voxel = [self getPointerToVoxelAtPoint:p];
                BOOL outside = y >= heightOfHighestVoxel;
                
                markVoxelAsOutside(outside, voxel);
            }
        }
    }
}


/* Computes voxelData which represents the voxel terrain values for the points between minP and maxP. The chunk is translated so
 * that voxelData[0,0,0] corresponds to (minX, minY, minZ). The size of the chunk is unscaled so that, for example, the width of
 * the chunk is equal to maxP-minP. Ditto for the other major axii.
 *
 * Assumes the caller already holds "lockVoxelData" for writing.
 */
- (void)generateVoxelDataWithCallback:(terrain_generator_t)generator
{
    //CFAbsoluteTime timeStart = CFAbsoluteTimeGetCurrent();
    
    for(ssize_t x = 0; x < CHUNK_SIZE_X; ++x)
    {
        for(ssize_t y = 0; y < CHUNK_SIZE_Y; ++y)
        {
            for(ssize_t z = 0; z < CHUNK_SIZE_Z; ++z)
            {
                generator(GSVector3_Add(GSVector3_Make(x, y, z), minP),
                          [self getPointerToVoxelAtPoint:GSIntegerVector3_Make(x, y, z)]);
                
                // whether the block is outside or not is calculated later
            }
       }
    }
    
    dirty = YES;
    
    //CFAbsoluteTime timeEnd = CFAbsoluteTimeGetCurrent();
    //NSLog(@"Finished generating chunk voxel data. It took %.3fs", timeEnd - timeStart);
}


/* Returns YES if the chunk data is reachable on the filesystem and loading was successful.
 * Assumes the caller already holds "lockVoxelData" for writing.
 */
- (void)loadVoxelDataFromFile:(NSURL *)url
{
    const size_t len = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t);
    
    // Read the contents of the file into "voxelData".
    NSData *data = [[NSData alloc] initWithContentsOfURL:url];
    if([data length] != len) {
        [NSException raise:@"Runtime Error"
                    format:@"Unexpected length of data for chunk. Got %zu bytes. Expected %zu bytes.", (size_t)[data length], len];
    }
    [data getBytes:voxelData length:len];
    [data release];
    
    dirty = NO;
}


/* Assumes the caller is already holding "lockVoxelData".
 * Returns YES if any of the empty, adjacent blocks are lit to the specified light level.
 * NOTE: This totally ignores the neighboring chunks.
 */
- (BOOL)isAdjacentToSunlightAtPoint:(GSIntegerVector3)p lightLevel:(int)lightLevel
{
    if(p.y+1 >= CHUNK_SIZE_Y) {
        return YES;
    } else if(isVoxelEmpty(voxelData[INDEX(p.x, p.y+1, p.z)]) && sunlight[INDEX(p.x, p.y+1, p.z)] == lightLevel) {
        return YES;
    }
    
    if(p.y-1 >= 0 && isVoxelEmpty(voxelData[INDEX(p.x, p.y-1, p.z)]) && sunlight[INDEX(p.x, p.y-1, p.z)] == lightLevel) {
        return YES;
    }
    
    if(p.x-1 >= 0 && isVoxelEmpty(voxelData[INDEX(p.x-1, p.y, p.z)]) && sunlight[INDEX(p.x-1, p.y, p.z)] == lightLevel) {
        return YES;
    }
    
    if(p.x+1 < CHUNK_SIZE_X && isVoxelEmpty(voxelData[INDEX(p.x+1, p.y, p.z)]) && sunlight[INDEX(p.x+1, p.y, p.z)] == lightLevel) {
        return YES;
    }
    
    if(p.z-1 >= 0 && isVoxelEmpty(voxelData[INDEX(p.x, p.y, p.z-1)]) && sunlight[INDEX(p.x, p.y, p.z-1)] == lightLevel) {
        return YES;
    }
    
    if(p.z+1 < CHUNK_SIZE_Z && isVoxelEmpty(voxelData[INDEX(p.x, p.y, p.z+1)]) && sunlight[INDEX(p.x, p.y, p.z+1)] == lightLevel) {
        return YES;
    }
    
    return NO;
}


// Assumes the caller has already holding "lockSunlight" for writing.
- (void)clearSunlightBuffer
{
    if(!sunlight) {
        sunlight = calloc(CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z, sizeof(int8_t));
        if(!sunlight) {
            [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for sunlight array."];
        }
    } else {
        bzero(sunlight, sizeof(int8_t) * CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z);
    }
}


// Assumes the caller has already holding "lockSunlight" for writing and "lockVoxelData" for reading.
- (void)computeHardLocalSunlight
{
    GSIntegerVector3 p;
    for(p.x = 0; p.x < CHUNK_SIZE_X; ++p.x)
    {
        for(p.y = 0; p.y < CHUNK_SIZE_Y; ++p.y)
        {
            for(p.z = 0; p.z < CHUNK_SIZE_Z; ++p.z)
            {
                size_t idx = INDEX(p.x, p.y, p.z);
                assert(idx >= 0 && idx < (CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z));
                
                // This is "hard" lighting with exactly two lighting levels.
                // Solid blocks always have zero sunlight. They pick up light from surrounding air.
                if(isVoxelEmpty(voxelData[idx]) && isVoxelOutside(voxelData[idx])) {
                    sunlight[idx] = CHUNK_LIGHTING_MAX;
                }
            }
        }
    }
}


/* Generates sunlight values for all blocks in the chunk.
 * Assumes the caller has already holding "lockSunlight" for writing, and "lockVoxelData" for reading,
 * for all chunks in the neighborhood.
 */
- (void)floodFillSunlightAtPoint:(GSIntegerVector3)p
                       neighbors:(GSNeighborhood *)neighbors
                       intensity:(int)intensity
{
    if(intensity < 0) {
        return;
    }
    
    if(p.y < 0 || p.y >= CHUNK_SIZE_Y) {
        return;
    }
    
    GSIntegerVector3 ap = p;
    GSChunkVoxelData *voxels = [neighbors getNeighborVoxelAtPoint:&ap]; // `ap' is adjusted to be relative to `voxels' local space
    uint8_t *value = [voxels getPointerToSunlightAtPoint:ap];
    
    if(!isVoxelEmpty([voxels getVoxelAtPoint:ap])) {
        *value = 0; // solid voxels always have zero sunlight
        return;
    }
    
    if(*value > intensity) {
        return;
    }
    
    *value = intensity;
    
    // recursive flood-fill
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x+1, p.y, p.z) neighbors:neighbors intensity:intensity-1];
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x-1, p.y, p.z) neighbors:neighbors intensity:intensity-1];
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x, p.y+1, p.z) neighbors:neighbors intensity:intensity-1];
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x, p.y-1, p.z) neighbors:neighbors intensity:intensity-1];
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x, p.y, p.z+1) neighbors:neighbors intensity:intensity-1];
    [self floodFillSunlightAtPoint:GSIntegerVector3_Make(p.x, p.y, p.z-1) neighbors:neighbors intensity:intensity-1];
}


/* Generates sunlight values for all blocks in the chunk.
 * Assumes the caller has already holding "lockSunlight" for writing, and "lockVoxelData" for reading,
 * for all chunks in the neighborhood.
 */
- (void)generateSunlightWithNeighbors:(GSNeighborhood *)neighbors
{
    GSIntegerVector3 p;
    
    NSMutableArray *floodFillLights = [[NSMutableArray alloc] init];
    
    /* Find empty blocks that are not outside, but are adjacent to outside blocks.
     * These will be used as the starting points for a lighting flood-fill operation.
     */
    for(p.x = 0; p.x < CHUNK_SIZE_X; ++p.x)
    {
        for(p.y = 0; p.y < CHUNK_SIZE_Y; ++p.y)
        {
            for(p.z = 0; p.z < CHUNK_SIZE_Z; ++p.z)
            {
                size_t idx = INDEX(p.x, p.y, p.z);
                assert(idx >= 0 && idx < (CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z));
                
                if(!isVoxelOutside(voxelData[idx]) && [self isAdjacentToSunlightAtPoint:p lightLevel:CHUNK_LIGHTING_MAX]) {
                    [floodFillLights addObject:[GSBoxedVector boxedVectorWithIntegerVector:p]];
                }
            }
        }
    }
    
    /* For each light, perform a flood-fill to propagate sunlight throughout the chunk and perhaps to neighboring chunks.
     * The order that sunlight is calculated for neighboring chunks does not affect the final sunlight value. Races are not a
     * problem.
     */
    for(GSBoxedVector *b in floodFillLights)
    {
        [self floodFillSunlightAtPoint:[b integerVectorValue]
                             neighbors:neighbors
                             intensity:CHUNK_LIGHTING_MAX-1];
    }
    
    [floodFillLights release];
}

@end