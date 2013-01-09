//
//  GSChunkVoxelData.m
//  GutsyStorm
//
//  Created by Andrew Fox on 4/17/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import <GLKit/GLKMath.h>
#import "GSChunkVoxelData.h"
#import "GSRay.h"
#import "GSBoxedVector.h"
#import "GSChunkStore.h"

static const GSIntegerVector3 combinedMinP = {-CHUNK_SIZE_X, 0, -CHUNK_SIZE_Z};
static const GSIntegerVector3 combinedMaxP = {2*CHUNK_SIZE_X, CHUNK_SIZE_Y, 2*CHUNK_SIZE_Z};

@interface GSChunkVoxelData (Private)

- (void)destroyVoxelData;
- (void)allocateVoxelData;
- (NSError *)loadVoxelDataFromFile:(NSURL *)url;
- (void)recalcOutsideVoxelsNoLock;
- (void)generateVoxelDataWithGenerator:(terrain_generator_t)generator
                         postProcessor:(terrain_post_processor_t)postProcessor;
- (void)saveVoxelDataToFile;
- (void)saveSunlightDataToFile;
- (void)loadOrGenerateVoxelData:(terrain_generator_t)generator
                  postProcessor:(terrain_post_processor_t)postProcessor
              completionHandler:(void (^)(void))completionHandler;
- (void)tryToLoadSunlightData;
- (BOOL)tryToRebuildSunlightWithNeighborhood:(GSNeighborhood *)neighborhood
                                        tier:(unsigned)tier
                           completionHandler:(void (^)(void))completionHandler;

@end


@implementation GSChunkVoxelData
{
    NSURL *_folder;
    dispatch_group_t _groupForSaving;
    dispatch_queue_t _chunkTaskQueue;
    int _updateForSunlightInFlight;
}

+ (NSString *)fileNameForVoxelDataFromMinP:(GLKVector3)minP
{
    return [NSString stringWithFormat:@"%.0f_%.0f_%.0f.voxels.dat", minP.x, minP.y, minP.z];
}

+ (NSString *)fileNameForSunlightDataFromMinP:(GLKVector3)minP
{
    return [NSString stringWithFormat:@"%.0f_%.0f_%.0f.sunlight.dat", minP.x, minP.y, minP.z];
}

- (id)initWithMinP:(GLKVector3)minP
            folder:(NSURL *)folder
    groupForSaving:(dispatch_group_t)groupForSaving
    chunkTaskQueue:(dispatch_queue_t)chunkTaskQueue
         generator:(terrain_generator_t)generator
     postProcessor:(terrain_post_processor_t)postProcessor
{
    self = [super initWithMinP:minP];
    if (self) {
        assert(CHUNK_LIGHTING_MAX < MIN(CHUNK_SIZE_X, CHUNK_SIZE_Z));
        
        _groupForSaving = groupForSaving; // dispatch group used for tasks related to saving chunks to disk
        dispatch_retain(_groupForSaving);
        
        _chunkTaskQueue = chunkTaskQueue; // dispatch queue used for chunk background work
        dispatch_retain(_chunkTaskQueue);
        
        _folder = folder;
        
        _lockVoxelData = [[GSReaderWriterLock alloc] init];
        [_lockVoxelData lockForWriting]; // This is locked initially and unlocked at the end of the first update.
        _voxelData = NULL;
        
        _sunlight = [[GSLightingBuffer alloc] initWithDimensions:GSIntegerVector3_Make(3*CHUNK_SIZE_X,CHUNK_SIZE_Y,3*CHUNK_SIZE_Z)];
        _dirtySunlight = YES;
        
        // The initial loading from disk preceeds all attempts to generate new sunlight data.
        OSAtomicCompareAndSwapIntBarrier(0, 1, &_updateForSunlightInFlight);
        
        // Fire off asynchronous task to load or generate voxel data.
        dispatch_async(_chunkTaskQueue, ^{
            [self allocateVoxelData];
            
            [self tryToLoadSunlightData];
            OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateForSunlightInFlight); // reset
            
            [self loadOrGenerateVoxelData:generator
                            postProcessor:postProcessor
                        completionHandler:^{
                [self recalcOutsideVoxelsNoLock];
                [_lockVoxelData unlockForWriting];
                // We don't need to call -voxelDataWasModified in the special case of initialization.
            }];
        });
    }
    
    return self;
}

- (void)dealloc
{
    dispatch_release(_groupForSaving);
    dispatch_release(_chunkTaskQueue);
    [self destroyVoxelData];
}

// Assumes the caller is already holding "lockVoxelData".
- (voxel_t)voxelAtLocalPosition:(GSIntegerVector3)p
{
    return *[self pointerToVoxelAtLocalPosition:p];
}

// Assumes the caller is already holding "lockVoxelData".
- (voxel_t *)pointerToVoxelAtLocalPosition:(GSIntegerVector3)p
{
    assert(_voxelData);
    assert(p.x >= 0 && p.x < CHUNK_SIZE_X);
    assert(p.y >= 0 && p.y < CHUNK_SIZE_Y);
    assert(p.z >= 0 && p.z < CHUNK_SIZE_Z);
    
    size_t idx = INDEX_BOX(p, ivecZero, chunkSize);
    assert(idx >= 0 && idx < (CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z));
    
    return &_voxelData[idx];
}

- (void)voxelDataWasModified
{
    [self recalcOutsideVoxelsNoLock];
    
    // Caller must make sure to update sunlight later...
    _dirtySunlight = YES;
    
    // Spin off a task to save the chunk.
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_group_async(_groupForSaving, queue, ^{
        [_lockVoxelData lockForReading];
        [self saveVoxelDataToFile];
        [_lockVoxelData unlockForReading];
    });
}

- (void)readerAccessToVoxelDataUsingBlock:(void (^)(void))block
{
    [_lockVoxelData lockForReading];
    block();
    [_lockVoxelData unlockForReading];
}

- (BOOL)tryReaderAccessToVoxelDataUsingBlock:(void (^)(void))block
{
    if(![_lockVoxelData tryLockForReading]) {
        return NO;
    } else {
        block();
        [_lockVoxelData unlockForReading];
        return YES;
    }
}

- (void)writerAccessToVoxelDataUsingBlock:(void (^)(void))block
{
    [_lockVoxelData lockForWriting];
    block();
    [self voxelDataWasModified];
    [_lockVoxelData unlockForWriting];
}

/* Copy the voxel data for the neighborhood into a new buffer and return the buffer. If the method would block when taking the
 * locks on the neighborhood then instead return NULL. The returned buffer is (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y
 * elements in size and may be indexed using the INDEX2 macro.
 * Assumes the caller has already locked the voxelData for chunks in the neighborhood (for reading).
 */
- (voxel_t *)newVoxelBufferWithNeighborhood:(GSNeighborhood *)neighborhood
{
    static const size_t size = (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y;
    
    // Allocate a buffer large enough to hold a copy of the entire neighborhood's voxels
    voxel_t *combinedVoxelData = combinedVoxelData = malloc(size*sizeof(voxel_t));
    if(!combinedVoxelData) {
        [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for combinedVoxelData."];
    }
    
    static ssize_t offsetsX[CHUNK_NUM_NEIGHBORS];
    static ssize_t offsetsZ[CHUNK_NUM_NEIGHBORS];
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        for(neighbor_index_t i=0; i<CHUNK_NUM_NEIGHBORS; ++i)
        {
            GLKVector3 offset = [GSNeighborhood offsetForNeighborIndex:i];
            offsetsX[i] = offset.x;
            offsetsZ[i] = offset.z;
        }
    });
    
    [neighborhood enumerateNeighborsWithBlock2:^(neighbor_index_t i, GSChunkVoxelData *voxels) {
        const voxel_t *data = voxels.voxelData;
        ssize_t offsetX = offsetsX[i];
        ssize_t offsetZ = offsetsZ[i];
        
        GSIntegerVector3 p;
        FOR_Y_COLUMN_IN_BOX(p, ivecZero, chunkSize)
        {
            assert(p.x >= 0 && p.x < chunkSize.x);
            assert(p.y >= 0 && p.y < chunkSize.y);
            assert(p.z >= 0 && p.z < chunkSize.z);
            
            size_t dstIdx = INDEX_BOX(GSIntegerVector3_Make(p.x+offsetX, p.y, p.z+offsetZ), combinedMinP, combinedMaxP);
            size_t srcIdx = INDEX_BOX(p, ivecZero, chunkSize);
            
            assert(dstIdx < size);
            assert(srcIdx < (CHUNK_SIZE_X*CHUNK_SIZE_Y*CHUNK_SIZE_Z));
            assert(sizeof(combinedVoxelData[0]) == sizeof(data[0]));

            memcpy(&combinedVoxelData[dstIdx], &data[srcIdx], CHUNK_SIZE_Y*sizeof(combinedVoxelData[0]));
        }
    }];
    
    return combinedVoxelData;
}

- (BOOL)isAdjacentToSunlightAtPoint:(GSIntegerVector3)p
                         lightLevel:(int)lightLevel
                  combinedVoxelData:(voxel_t *)combinedVoxelData
       combinedSunlightData:(uint8_t *)combinedSunlightData
{
    for(face_t i=0; i<FACE_NUM_FACES; ++i)
    {
        GSIntegerVector3 a = GSIntegerVector3_Add(p, offsetForFace[i]);
        
        if(a.x < -CHUNK_SIZE_X || a.x >= (2*CHUNK_SIZE_X) ||
           a.z < -CHUNK_SIZE_Z || a.z >= (2*CHUNK_SIZE_Z) ||
           a.y < 0 || a.y >= CHUNK_SIZE_Y) {
            continue; // The point is out of bounds, so bail out.
        }
        
        size_t idx = INDEX_BOX(a, combinedMinP, combinedMaxP);
        
        if(combinedVoxelData[idx].opaque) {
            continue;
        }
        
        if(combinedSunlightData[idx] == lightLevel) {
            return YES;
        }
    }
    
    return NO;
}

/* Generate and return  sunlight data for this chunk from the specified voxel data buffer. The voxel data buffer must be
 * (3*CHUNK_SIZE_X)*(3*CHUNK_SIZE_Z)*CHUNK_SIZE_Y elements in size and should contain voxel data for the entire local neighborhood.
 * The returned sunlight buffer is also this size and may also be indexed using the INDEX2 macro. Only the sunlight values for the
 * region of the buffer corresponding to this chunk should be considered to be totally correct.
 * Assumes the caller has already locked the sunlight buffer for reading (sunlight.lockLightingBuffer).
 */
- (void)fillSunlightBufferUsingCombinedVoxelData:(voxel_t *)combinedVoxelData
{
    GSIntegerVector3 p;
    
    uint8_t *combinedSunlightData = _sunlight.lightingBuffer;
    
    FOR_BOX(p, combinedMinP, combinedMaxP)
    {
        size_t idx = INDEX_BOX(p, combinedMinP, combinedMaxP);
        voxel_t voxel = combinedVoxelData[idx];
        BOOL directlyLit = (!voxel.opaque) && (voxel.outside);
        combinedSunlightData[idx] = directlyLit ? CHUNK_LIGHTING_MAX : 0;
    }

    // Find blocks that have not had light propagated to them yet and are directly adjacent to blocks at X light.
    // Repeat for all light levels from CHUNK_LIGHTING_MAX down to 1.
    // Set the blocks we find to the next lower light level.
    for(int lightLevel = CHUNK_LIGHTING_MAX; lightLevel >= 1; --lightLevel)
    {
        FOR_BOX(p, combinedMinP, combinedMaxP)
        {
            size_t idx = INDEX_BOX(p, combinedMinP, combinedMaxP);
            voxel_t voxel = combinedVoxelData[idx];
            
            if(voxel.opaque || voxel.outside) {
                continue;
            }
            
            if([self isAdjacentToSunlightAtPoint:p
                                      lightLevel:lightLevel
                               combinedVoxelData:combinedVoxelData
                    combinedSunlightData:combinedSunlightData]) {
                combinedSunlightData[idx] = MAX(combinedSunlightData[idx], lightLevel - 1);
            }
        }
    }
}

- (BOOL)tryToRebuildSunlightWithNeighborhood:(GSNeighborhood *)neighborhood
                           completionHandler:(void (^)(void))completionHandler
{
    return [self tryToRebuildSunlightWithNeighborhood:neighborhood tier:0 completionHandler:completionHandler];
}

@end

@implementation GSChunkVoxelData (Private)

// Assumes the caller is already holding "lockVoxelData" for reading.
- (void)saveVoxelDataToFile
{
    const size_t len = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t);
    
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForVoxelDataFromMinP:self.minP]
                        relativeToURL:_folder];
    
    [[NSData dataWithBytes:_voxelData length:len] writeToURL:url atomically:YES];
}

- (void)saveSunlightDataToFile
{
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForSunlightDataFromMinP:self.minP]
                        relativeToURL:_folder];
    [_sunlight saveToFile:url];
}

// Assumes the caller is already holding "lockVoxelData".
- (void)allocateVoxelData
{
    [self destroyVoxelData];
    
    _voxelData = malloc(CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t));
    if(!_voxelData) {
        [NSException raise:@"Out of Memory" format:@"Failed to allocate memory for chunk's voxelData"];
    }
}

// Assumes the caller is already holding "lockVoxelData".
- (void)destroyVoxelData
{
    free(_voxelData);
    _voxelData = NULL;
}

// Assumes the caller is already holding "lockVoxelData".
- (void)recalcOutsideVoxelsNoLock
{
    GSIntegerVector3 p;

    // Determine voxels in the chunk which are outside. That is, voxels which are directly exposed to the sky from above.
    // We assume here that the chunk is the height of the world.
    FOR_Y_COLUMN_IN_BOX(p, ivecZero, chunkSize)
    {
        // Get the y value of the highest non-empty voxel in the chunk.
        ssize_t heightOfHighestVoxel;
        for(heightOfHighestVoxel = CHUNK_SIZE_Y-1; heightOfHighestVoxel >= 0; --heightOfHighestVoxel)
        {
            voxel_t *voxel = [self pointerToVoxelAtLocalPosition:GSIntegerVector3_Make(p.x, heightOfHighestVoxel, p.z)];
            
            if(voxel->opaque) {
                break;
            }
        }
        
        for(p.y = 0; p.y < chunkSize.y; ++p.y)
        {
            [self pointerToVoxelAtLocalPosition:p]->outside = (p.y >= heightOfHighestVoxel);
        }
    }

    // Determine voxels in the chunk which are exposed to air on top.
    FOR_Y_COLUMN_IN_BOX(p, ivecZero, chunkSize)
    {
        // Find a voxel which is empty and is directly above a cube voxel.
        p.y = CHUNK_SIZE_Y-1;
        voxel_type_t prevType = [self pointerToVoxelAtLocalPosition:p]->type;
        for(p.y = CHUNK_SIZE_Y-2; p.y >= 0; --p.y)
        {
            voxel_t *voxel = [self pointerToVoxelAtLocalPosition:p];

            // XXX: It would be better to store the relationships between voxel types in some other way. Not here.
            voxel->exposedToAirOnTop = (voxel->type!=VOXEL_TYPE_EMPTY && prevType==VOXEL_TYPE_EMPTY) ||
                                       (voxel->type==VOXEL_TYPE_CUBE && prevType==VOXEL_TYPE_CORNER_OUTSIDE) ||
                                       (voxel->type==VOXEL_TYPE_CORNER_INSIDE && prevType==VOXEL_TYPE_CORNER_OUTSIDE) ||
                                       (voxel->type==VOXEL_TYPE_CUBE && prevType==VOXEL_TYPE_RAMP);

            prevType = voxel->type;
        }
    }
}

/* Computes voxelData which represents the voxel terrain values for the points between minP and maxP. The chunk is translated so
 * that voxelData[0,0,0] corresponds to (minX, minY, minZ). The size of the chunk is unscaled so that, for example, the width of
 * the chunk is equal to maxP-minP. Ditto for the other major axii.
 *
 * Assumes the caller already holds "lockVoxelData" for writing.
 */
- (void)generateVoxelDataWithGenerator:(terrain_generator_t)generator
                         postProcessor:(terrain_post_processor_t)postProcessor
{
    GSIntegerVector3 p, a, b;
    a = GSIntegerVector3_Make(-1, 0, -1);
    b = GSIntegerVector3_Make(chunkSize.x+1, chunkSize.y, chunkSize.z+1);

    const size_t count = (b.x-a.x) * (b.y-a.y) * (b.z-a.z);
    voxel_t *voxels = calloc(count, sizeof(voxel_t));

    // First, generate voxels for the region of the chunk, plus a 1 block wide border.
    // Note that whether the block is outside or not is calculated later.
    FOR_BOX(p, a, b)
    {
        generator(GLKVector3Add(GLKVector3Make(p.x, p.y, p.z), self.minP), &voxels[INDEX_BOX(p, a, b)]);
    }

    // Post-process the voxels to add ramps, &c.
    postProcessor(count, voxels, a, b);

    // Copy the voxels for the chunk to their final destination.
    FOR_BOX(p, ivecZero, chunkSize)
    {
        _voxelData[INDEX_BOX(p, ivecZero, chunkSize)] = voxels[INDEX_BOX(p, a, b)];
    }

    free(voxels);
}

// Attempt to load chunk data from file asynchronously.
- (NSError *)loadVoxelDataFromFile:(NSURL *)url
{
    const size_t len = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * sizeof(voxel_t);
    
    if(![url checkResourceIsReachableAndReturnError:NULL]) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSFileNotFoundError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"Voxel data file is not present."}];
    }
    
    // Read the contents of the file into "voxelData".
    NSData *data = [[NSData alloc] initWithContentsOfURL:url];
    if([data length] != len) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"Voxel data file is of unexpected length."}];
    }
    [data getBytes:_voxelData length:len];
    
    return nil;
}

- (void)loadOrGenerateVoxelData:(terrain_generator_t)generator
                  postProcessor:(terrain_post_processor_t)postProcessor
              completionHandler:(void (^)(void))completionHandler
{
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForVoxelDataFromMinP:self.minP] relativeToURL:_folder];
    NSError *error = [self loadVoxelDataFromFile:url];
    
    if(error) {
        if((error.code == GSInvalidChunkDataOnDiskError) || (error.code == GSFileNotFoundError)) {
            [self generateVoxelDataWithGenerator:generator
                                   postProcessor:postProcessor];

            dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
            dispatch_group_async(_groupForSaving, queue, ^{
                [_lockVoxelData lockForReading];
                [self saveVoxelDataToFile];
                [_lockVoxelData unlockForReading];
            });
        } else {
            [NSException raise:@"Runtime Error" format:@"Error %ld: %@", (long)error.code, error.localizedDescription];
        }
    }

    completionHandler();
}

- (void)tryToLoadSunlightData
{
    NSURL *url = [NSURL URLWithString:[GSChunkVoxelData fileNameForSunlightDataFromMinP:self.minP]
                        relativeToURL:_folder];
    
    [_sunlight tryToLoadFromFile:url completionHandler:^{
        _dirtySunlight = NO;
    }];
}

/* Try to immediately update sunlight using voxel data for the local neighborhood. If it is not possible to immediately take all
 * the locks on necessary resources then this method aborts the update and returns NO. If it is able to complete the update
 * successfully then it returns YES and marks this GSChunkVoxelData as being clean. (dirtySunlight=NO)
 * If the update was able to complete succesfully then the completionHandler block is called.
 *
 * There are several levels of locks which are taken recursively. The level of recursion is indicated using the `tier' parameter.
 * The top-level caller should always call with tier==0.
 */
- (BOOL)tryToRebuildSunlightWithNeighborhood:(GSNeighborhood *)neighborhood
                                        tier:(unsigned)tier
                           completionHandler:(void (^)(void))completionHandler
{
    assert(neighborhood);
    assert(tier < 3);

    switch(tier)
    {
        case 0:
        {
            BOOL success = NO;

            if(!OSAtomicCompareAndSwapIntBarrier(0, 1, &_updateForSunlightInFlight)) {
                DebugLog(@"Can't update sunlight: already in-flight.");
            } else {
                success = [self tryToRebuildSunlightWithNeighborhood:neighborhood
                                                                tier:1
                                                   completionHandler:completionHandler];

                OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateForSunlightInFlight); // reset
            }

            return success;
        }
            
        case 1:
        {
            BOOL success = NO;

            if(![_sunlight.lockLightingBuffer tryLockForWriting]) {
                DebugLog(@"Can't update sunlight: sunlight buffer is busy."); // This failure really shouldn't happen much...
            } else {
                success = [self tryToRebuildSunlightWithNeighborhood:neighborhood
                                                                tier:2
                                                   completionHandler:completionHandler];
                [_sunlight.lockLightingBuffer unlockForWriting];
            }

            return success;
        }

        case 2:
        {
            BOOL success = NO;

            // Try to copy the entire neighborhood's voxel data into one large buffer.
            __block voxel_t *buf = NULL;
            BOOL copyWasSuccessful = [neighborhood tryReaderAccessToVoxelDataUsingBlock:^{
                buf = [self newVoxelBufferWithNeighborhood:neighborhood];
            }];

            if(!copyWasSuccessful) {
                DebugLog(@"Can't update sunlight: voxel data buffers are busy.");
            } else {
                // Actually generate sunlight data.
                [self fillSunlightBufferUsingCombinedVoxelData:buf];

                _dirtySunlight = NO;
                success = YES;

                // Spin off a task to save sunlight data to disk.
                dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
                dispatch_group_async(_groupForSaving, queue, ^{
                    [self saveSunlightDataToFile];
                });

                completionHandler(); // Only call the completion handler if the update was successful.
            }

            free(buf);
            
            return success;
        }
    }
    
    assert(!"shouldn't get here");
    return NO;
}

@end