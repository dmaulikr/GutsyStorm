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


static const GSIntegerVector3 offsets[FACE_NUM_FACES] = {
    { 1, 0, 0},
    {-1, 0, 0},
    { 0, 1, 0},
    { 0,-1, 0},
    { 0, 0, 1},
    { 0, 0,-1},
};


@interface GSChunkVoxelData (Private)

- (void)destroyVoxelData;
- (void)allocateVoxelData;
- (void)loadVoxelDataFromFile:(NSURL *)url;
- (void)recalcOutsideVoxelsNoLock;
- (void)generateVoxelDataWithCallback:(terrain_generator_t)callback;
- (void)saveVoxelDataToFile;

@end


@implementation GSChunkVoxelData

@synthesize voxelData;
@synthesize sunlight;
@synthesize lockVoxelData;

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
        assert(CHUNK_LIGHTING_MAX < MIN(CHUNK_SIZE_X, CHUNK_SIZE_Z));
        
        groupForSaving = _groupForSaving; // dispatch group used for tasks related to saving chunks to disk
        dispatch_retain(groupForSaving);
        
        chunkTaskQueue = _chunkTaskQueue; // dispatch queue used for chunk background work
        dispatch_retain(_chunkTaskQueue);
        
        folder = _folder;
        [folder retain];
        
        lockVoxelData = [[GSReaderWriterLock alloc] init];
        [lockVoxelData lockForWriting]; // This is locked initially and unlocked at the end of the first update.
        voxelData = NULL;
        
        sunlight = [[GSLightingBuffer alloc] initWithDimensions:GSIntegerVector3_Make(3*CHUNK_SIZE_X,CHUNK_SIZE_Y,3*CHUNK_SIZE_Z)];
        
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
            [lockVoxelData unlockForWriting]; // We don't need to call -voxelDataWasModified in the special case of initialization.
        });
    }
    
    return self;
}


- (void)dealloc
{
    dispatch_release(groupForSaving);
    dispatch_release(chunkTaskQueue);
    [folder release];
    
    [self destroyVoxelData];
    [lockVoxelData release];
    
    [sunlight release];
    
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


- (void)voxelDataWasModified
{
    [self recalcOutsideVoxelsNoLock];
    
    // Caller must make sure to update sunlight later...
    
    /* Spin off a task to save the chunk.
     * This is latency sensitive, so submit to the global queue. Do not use `chunkTaskQueue' as that would cause the block to be
     * added to the end of a long queue of basically serialized background tasks.
     */
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_async(groupForSaving, queue, ^{
        [lockVoxelData lockForReading];
        [self saveVoxelDataToFile];
        [lockVoxelData unlockForReading];
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
    block(); // rely on caller to call -voxelDataWasModified
    [lockVoxelData unlockForWriting];
}


/* Copy the voxel data for the neighborhood into a new buffer and return the buffer. If the method would block when taking the
 * locks on the neighborhood then instead return NULL. The returned buffer is (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y
 * elements in size and may be indexed using the INDEX2 macro.
 */
- (voxel_t *)newCombinedVoxelDataBufferWithNeighborhood:(GSNeighborhood *)neighborhood
{
    static const size_t size = (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y;
    
    // Allocate a buffer large enough to hold a copy of the entire neighborhood's voxels
    voxel_t *combinedVoxelData = combinedVoxelData = malloc(size*sizeof(voxel_t));
    if(!combinedVoxelData) {
        [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for combinedVoxelData."];
    }
    
    [neighborhood readerAccessToVoxelDataUsingBlock:^{
        GSIntegerVector3 p;
        for(p.x = -CHUNK_SIZE_X; p.x < 2*CHUNK_SIZE_X; ++p.x)
        {
            for(p.y = 0; p.y < CHUNK_SIZE_Y; ++p.y)
            {
                for(p.z = -CHUNK_SIZE_Z; p.z < 2*CHUNK_SIZE_Z; ++p.z)
                {
                    GSIntegerVector3 ap = p;
                    GSChunkVoxelData *chunk = [neighborhood getNeighborVoxelAtPoint:&ap];
                    combinedVoxelData[INDEX2(p.x, p.y, p.z)] = chunk.voxelData[INDEX(ap.x, ap.y, ap.z)];
                }
            }
        }
    }];
    
    return combinedVoxelData;
}


- (BOOL)isAdjacentToSunlightAtPoint:(GSIntegerVector3)p
                         lightLevel:(int)lightLevel
                  combinedVoxelData:(voxel_t *)combinedVoxelData
       combinedSunlightData:(voxel_t *)combinedSunlightData
{
    for(face_t i=0; i<FACE_NUM_FACES; ++i)
    {
        GSIntegerVector3 a = GSIntegerVector3_Add(p, offsets[i]);
        
        if(a.x < -CHUNK_SIZE_X || a.x >= (2*CHUNK_SIZE_X) ||
           a.z < -CHUNK_SIZE_Z || a.z >= (2*CHUNK_SIZE_Z) ||
           a.y < 0 || a.y >= CHUNK_SIZE_Y) {
            continue; // The point is out of bounds, so bail out.
        }
        
        if(!isVoxelEmpty(combinedVoxelData[INDEX2(a.x, a.y, a.z)])) {
            continue;
        }
        
        if(combinedSunlightData[INDEX2(a.x, a.y, a.z)] == lightLevel) {
            return YES;
        }
    }
    
    return NO;
}


/* Generate and return  sunlight data for this chunk from the specified voxel data buffer. The voxel data buffer must be
 * (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y elements in size and should contain voxel data for the entire local neighborhood.
 * The returned sunlight buffer is also this size and may also be indexed using the INDEX2 macro. Only the sunlight values for the
 * region of the buffer corresponding to this chunk should be considered to be totally correct.
 */
- (voxel_t *)newCombinedSunlightBufferWithVoxelData:(voxel_t *)combinedVoxelData
{
    static const size_t size = (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y;
    GSIntegerVector3 p;
    
    // Allocate a buffer large enough to hold the entire neighborhood's sunlight values.
    uint8_t *combinedSunlightData = calloc(size, sizeof(uint8_t));
    if(!combinedSunlightData) {
        [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for combinedSunlightData."];
    }
    
    for(p.x = -CHUNK_SIZE_X; p.x < (2*CHUNK_SIZE_X); ++p.x)
    {
        for(p.y = 0; p.y < CHUNK_SIZE_Y; ++p.y)
        {
            for(p.z = -CHUNK_SIZE_Z; p.z < (2*CHUNK_SIZE_Z); ++p.z)
            {
                voxel_t voxel = combinedVoxelData[INDEX2(p.x, p.y, p.z)];
                if(isVoxelEmpty(voxel) && isVoxelOutside(voxel)) {
                    combinedSunlightData[INDEX2(p.x, p.y, p.z)] = CHUNK_LIGHTING_MAX;
                }
            }
        }
    }

    // Find blocks that have not had light propagated to them yet and are directly adjacent to blocks at X light.
    // Repeat for all light levels from CHUNK_LIGHTING_MAX down to 1.
    // Set the blocks we find to the next lower light level.
    for(int lightLevel = CHUNK_LIGHTING_MAX; lightLevel >= 1; --lightLevel)
    {
        for(p.x = -CHUNK_SIZE_X; p.x < (2*CHUNK_SIZE_X); ++p.x)
        {
            for(p.y = 0; p.y < CHUNK_SIZE_Y; ++p.y)
            {
                for(p.z = -CHUNK_SIZE_Z; p.z < (2*CHUNK_SIZE_Z); ++p.z)
                {
                    if(!isVoxelEmpty(combinedVoxelData[INDEX2(p.x, p.y, p.z)]) ||
                       isVoxelOutside(combinedVoxelData[INDEX2(p.x, p.y, p.z)])) {
                        continue;
                    }
                    
                    if([self isAdjacentToSunlightAtPoint:p
                                              lightLevel:lightLevel
                                       combinedVoxelData:combinedVoxelData
                            combinedSunlightData:combinedSunlightData]) {
                        uint8_t *val = &combinedSunlightData[INDEX2(p.x, p.y, p.z)];
                        *val = MAX(*val, lightLevel - 1);
                    }
                }
            }
        }
    }

    return combinedSunlightData;
}


/* Copy the region of specified buffer into this chunk's sunlight buffer. The provided data buffer must be
 * (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y elements in size.
 */
- (void)copyToSunlightBufferFromLargerBuffer:(voxel_t *)combinedSunlightData
{
    [sunlight.lockLightingBuffer lockForWriting];
    memcpy(sunlight.lightingBuffer, combinedSunlightData, (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y*sizeof(uint8_t));
    [sunlight.lockLightingBuffer unlockForWriting];
}


- (void)rebuildSunlightWithNeighborhood:(GSNeighborhood *)neighborhood
{
    //CFAbsoluteTime timeStart = CFAbsoluteTimeGetCurrent();
    
    // Copy the entire neighborhood's voxel data into the large buffer.
    voxel_t *combinedVoxelData = [self newCombinedVoxelDataBufferWithNeighborhood:neighborhood];
    
    uint8_t *combinedSunlightData = [self newCombinedSunlightBufferWithVoxelData:combinedVoxelData];
    
    free(combinedVoxelData);
    combinedVoxelData = NULL;
    
    [self copyToSunlightBufferFromLargerBuffer:combinedSunlightData];
    
    free(combinedSunlightData);
    combinedSunlightData = NULL;
    
    //CFAbsoluteTime timeEnd = CFAbsoluteTimeGetCurrent();
    //NSLog(@"Finished rebuilding sunlight. It took %.2fs", timeEnd - timeStart);
}

@end


@implementation GSChunkVoxelData (Private)

// Assumes the caller is already holding "lockVoxelData" for reading.
- (void)saveVoxelDataToFile
{
    const size_t len = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t);
    
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForVoxelDataFromMinP:minP]
                        relativeToURL:folder];
    
    [[NSData dataWithBytes:voxelData length:len] writeToURL:url atomically:YES];
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
}

@end