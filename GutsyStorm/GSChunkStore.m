//
//  GSChunkStore.m
//  GutsyStorm
//
//  Created by Andrew Fox on 3/24/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import <OpenGL/glu.h>
#import <assert.h>
#import <cache.h>
#import "GSRay.h"
#import "GSBoxedRay.h"
#import "GSBoxedVector.h"
#import "GSChunkStore.h"
#import "GSNoise.h"

static float groundGradient(float terrainHeight, GSVector3 p);
static void generateTerrainVoxel(unsigned seed, float terrainHeight, GSVector3 p, voxel_t *outVoxel);


@interface GSChunkStore (Private)

+ (NSURL *)newWorldSaveFolderURLWithSeed:(unsigned)seed;
- (void)updateChunkVisibilityForActiveRegion;
- (void)updateActiveChunksWithCameraModifiedFlags:(unsigned)flags;
- (GSNeighborhood *)neighborhoodAtPoint:(GSVector3)p;
- (GSChunkGeometryData *)chunkGeometryAtPoint:(GSVector3)p;
- (GSChunkVoxelData *)chunkVoxelsAtPoint:(GSVector3)p;

@end


@implementation GSChunkStore

+ (void)initialize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    if(![defaults objectForKey:@"ActiveRegionExtent"]) {
        NSDictionary *values = [NSDictionary dictionaryWithObjectsAndKeys:@"256", @"ActiveRegionExtent", nil];
        [[NSUserDefaults standardUserDefaults] registerDefaults:values];
    }
    
    if(![defaults objectForKey:@"NumVBOGenerationsAllowedPerFrame"]) {
        NSDictionary *values = [NSDictionary dictionaryWithObjectsAndKeys:@"64", @"NumVBOGenerationsAllowedPerFrame", nil];
        [[NSUserDefaults standardUserDefaults] registerDefaults:values];
    }
    
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (id)initWithSeed:(unsigned)_seed
            camera:(GSCamera *)_camera
     terrainShader:(GSShader *)_terrainShader
         glContext:(NSOpenGLContext *)_glContext
{
    self = [super init];
    if (self) {
        // Initialization code here.
        seed = _seed;
        terrainHeight = 40.0;
        folder = [GSChunkStore newWorldSaveFolderURLWithSeed:seed];
        groupForSaving = dispatch_group_create();
        
        camera = _camera;
        [camera retain];
        oldCenterChunkID = [GSChunkData chunkIDWithChunkMinCorner:[GSChunkData minCornerForChunkAtPoint:[camera cameraEye]]];
        [oldCenterChunkID retain];
        
        terrainShader = _terrainShader;
        [terrainShader retain];
        
        glContext = _glContext;
        [glContext retain];
        
        lock = [[NSLock alloc] init];
        
        /* VBO generation must be performed on the main thread.
         * To preserve responsiveness, limit the number of VBOs we create per frame.
         */
        NSInteger n = [[NSUserDefaults standardUserDefaults] integerForKey:@"NumVBOGenerationsAllowedPerFrame"];
        assert(n > 0 && n < INT_MAX);
        numVBOGenerationsAllowedPerFrame = (int)n;
        
        /* Why are we specfying the background-priority global dispatch queue here?
         *
         * Answer:
         * My use of locks does not work well with libdispatch. Neither does the way I'm handling the loading of chunks from disk.
         * When a dispatch block blocks the thread its running on, libdispatch will create a new thread to begin execution of the
         * next block in the queue (up to a limit). Because I'm using locks all over the place, I cause many, many new threads to be
         * created. These put too much load on the system, and cause the main thread to get less execution time; frame deadlines are
         * missed, and FPS drops. These threads eventually quiet down as computation to generate/load the active region is
         * completed. So, eventually, the "warm up" period ends, and FPS jumps up to a steady 60.
         *
         * The threads that execute blocks on background queue run with a less favorable scheduling priority, allowing the main
         * thread to meet its deadlines. They also run with I/O throttling per setpriority(2) and so is not a good long-term
         * solution.
         */
        chunkTaskQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
        
        gridGeometryData = [[GSGrid alloc] init];
        gridVoxelData = [[GSGrid alloc] init];
        
        // Do a full refresh fo the active region
        // Active region is bounded at y>=0.
        NSInteger w = [[NSUserDefaults standardUserDefaults] integerForKey:@"ActiveRegionExtent"];
        activeRegionExtent = GSVector3_Make(w, CHUNK_SIZE_Y, w);
        activeRegion = [[GSActiveRegion alloc] initWithActiveRegionExtent:activeRegionExtent];
        [activeRegion updateWithSorting:YES camera:camera chunkProducer:^GSChunkGeometryData *(GSVector3 p) {
            return [self chunkGeometryAtPoint:p];
        }];
        needsChunkVisibilityUpdate = 1;
        
    }
    
    return self;
}


- (void)waitForSaveToFinish
{
    [lock lock];
    NSLog(@"Waiting for all chunk-saving tasks to complete.");
    dispatch_group_wait(groupForSaving, DISPATCH_TIME_FOREVER); // wait for save operations to complete
    NSLog(@"All chunks have been saved.");
    [lock unlock];
}


- (void)dealloc
{
    [self waitForSaveToFinish];
    dispatch_release(groupForSaving);
    
    [gridVoxelData release];
    [gridGeometryData release];
    [camera release];
    [folder release];
    [terrainShader release];
    [glContext release];
    [lock release];
    [activeRegion release];
    dispatch_release(chunkTaskQueue);
    
    [super dealloc];
}


- (void)drawActiveChunks
{
    [terrainShader bind];
    
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_NORMAL_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);
    
    glTranslatef(0.5, 0.5, 0.5);
    
    // Update chunk visibility flags now. We've been told it's necessary.
    if(OSAtomicCompareAndSwapIntBarrier(1, 0, &needsChunkVisibilityUpdate)) {
        [self updateChunkVisibilityForActiveRegion];
    }

    __block NSUInteger numVBOGenerationsRemaining = numVBOGenerationsAllowedPerFrame;
    [activeRegion enumerateActiveChunkWithBlock:^(GSChunkGeometryData *chunk) {
        assert(chunk);
        if(chunk->visible && [chunk drawGeneratingVBOsIfNecessary:(numVBOGenerationsRemaining>0)]) {
            numVBOGenerationsRemaining--;
        };
    }];
    
    glDisableClientState(GL_COLOR_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
    glDisableClientState(GL_VERTEX_ARRAY);
    
    [terrainShader unbind];
}


// Try to update asynchronously dirty chunk sunlight. Skip any that would block due to lock contention.
- (void)tryToUpdateDirtySunlight
{
    dispatch_async(chunkTaskQueue, ^{
        void (^b)(GSVector3) = ^(GSVector3 p) {
            GSChunkVoxelData *voxels = [self chunkVoxelsAtPoint:p];
            dispatch_async(chunkTaskQueue, ^{
                if(voxels.dirtySunlight) {
                    GSNeighborhood *neighborhood = [self neighborhoodAtPoint:voxels.centerP];
                    [voxels tryToRebuildSunlightWithNeighborhood:neighborhood completionHandler:^{
                        GSChunkGeometryData *geometry = [self chunkGeometryAtPoint:p];
                        geometry.dirty = YES;
                        [geometry tryToUpdateWithVoxelData:neighborhood]; // make an effort to update geometry immediately
                    }];
                }
            });
        };
        
        [activeRegion enumeratePointsInActiveRegionNearCamera:camera usingBlock:b];
    });
}


// Try to asynchronously update dirty chunk geometry. Skip any that would block due to lock contention.
- (void)tryToUpdateDirtyGeometry
{
    dispatch_async(chunkTaskQueue, ^{
        void (^b)(GSChunkGeometryData *) = ^(GSChunkGeometryData *geometry) {
            dispatch_async(chunkTaskQueue, ^{
                if(geometry.dirty) {
                    [geometry tryToUpdateWithVoxelData:[self neighborhoodAtPoint:geometry.centerP]];
                }
            });
        };
        
        [activeRegion enumerateActiveChunkWithBlock:b];
    });
}


- (void)updateWithDeltaTime:(float)dt cameraModifiedFlags:(unsigned)flags
{
    [self tryToUpdateDirtySunlight];
    [self tryToUpdateDirtyGeometry];    
    [self updateActiveChunksWithCameraModifiedFlags:flags];
}


- (void)placeBlockAtPoint:(GSVector3)pos block:(voxel_t)newBlock
{
    GSChunkVoxelData *chunk = [self chunkVoxelsAtPoint:pos];
    [chunk writerAccessToVoxelDataUsingBlock:^{
        GSVector3 chunkLocalP;
        voxel_t *block;
        
        chunkLocalP = GSVector3_Sub(pos, chunk.minP);
        
        block = [chunk pointerToVoxelAtLocalPosition:GSIntegerVector3_Make(chunkLocalP.x, chunkLocalP.y, chunkLocalP.z)];
        assert(block);
        
        *block = newBlock;
    }];
    
    /* Invalidate sunlight data and geometry for the modified chunk and surrounding chunks.
     * Chunks' sunlight and geometry will be updated on the next update tick.
     */
    [[self neighborhoodAtPoint:pos] enumerateNeighborsWithBlock:^(GSChunkVoxelData *voxels) {
        voxels.dirtySunlight = YES;
        [self chunkGeometryAtPoint:voxels.centerP].dirty = YES;
    }];
}


- (voxel_t)voxelAtPoint:(GSVector3)pos
{
    __block voxel_t block;
    GSChunkVoxelData *chunk = [self chunkVoxelsAtPoint:pos];
    
    [chunk readerAccessToVoxelDataUsingBlock:^{
        GSVector3 chunkLocalP = GSVector3_Sub(pos, chunk.minP);
        block = [chunk voxelAtLocalPosition:GSIntegerVector3_Make(chunkLocalP.x, chunkLocalP.y, chunkLocalP.z)];
    }];
    
    return block;
}


/* Get the distance to the first intersection of the ray with a solid block.
 * A distance before the intersection will be returned in outDistanceBefore.
 * A distance after the intersection will be returned in outDistanceAfter.
 * Will not look farther than maxDist.
 * Returns YES if an intersection could be found, false otherwise.
 */
- (BOOL)positionOfBlockAlongRay:(GSRay)ray
                        maxDist:(float)maxDist
              outDistanceBefore:(float *)outDistanceBefore
               outDistanceAfter:(float *)outDistanceAfter
{
    [lock lock];
    
    assert(maxDist > 0);
    
    const size_t MAX_PASSES = 6;
    const float step[MAX_PASSES] = {1.0f, 0.1f, 0.01f, 0.001f, 0.0001f, 0.00001f};
    
    BOOL foundAnything = NO;
    float d = 0, prevD = 0;
    
    for(size_t i = 0; i < MAX_PASSES; ++i)
    {
        // Sweep forward to find the intersection point.
        for(d = prevD; d < maxDist; d += step[i])
        {
            GSVector3 pos = GSVector3_Add(ray.origin, GSVector3_Scale(GSVector3_Normalize(ray.direction), d));
            
            // world does not extend below y=0
            if(pos.y < 0) {
                [lock unlock];
                return NO;
            }
            
            // world does not extend below y=activeRegionExtent.y
            if(pos.y >= activeRegionExtent.y) {
                [lock unlock];
                return NO;
            }
            
            voxel_t block = [self voxelAtPoint:pos];
            
            if(!isVoxelEmpty(block)) {
                foundAnything = YES;
                break;
            }
            
            prevD = d;
        }
        
        if(!foundAnything) {
            [lock unlock];
            return NO;
        }
    }
    
    if(outDistanceBefore) {
        *outDistanceBefore = prevD;
    }
    
    if(outDistanceAfter) {
        *outDistanceAfter = d;
    }
    
    [lock unlock];
    return YES;
}

@end


@implementation GSChunkStore (Private)

- (GSNeighborhood *)neighborhoodAtPoint:(GSVector3)p
{
    GSNeighborhood *neighborhood = [[[GSNeighborhood alloc] init] autorelease];
    
    for(neighbor_index_t i = 0; i < CHUNK_NUM_NEIGHBORS; ++i)
    {
        GSVector3 a = GSVector3_Add(p, [GSNeighborhood offsetForNeighborIndex:i]);
        [neighborhood setNeighborAtIndex:i neighbor:[self chunkVoxelsAtPoint:a]];
    }
    
    return neighborhood;
}


- (GSChunkGeometryData *)chunkGeometryAtPoint:(GSVector3)p
{
    assert(p.y >= 0); // world does not extend below y=0
    assert(p.y < activeRegionExtent.y); // world does not extend above y=activeRegionExtent.y
    
    GSChunkGeometryData *g = [gridGeometryData objectAtPoint:p objectFactory:^id(GSVector3 minP) {
        // Chunk geometry will be generated later and is only marked "dirty" for now.
        return [[[GSChunkGeometryData alloc] initWithMinP:minP glContext:glContext] autorelease];
    }];
    
    return g;
}


- (GSChunkVoxelData *)chunkVoxelsAtPoint:(GSVector3)p
{
    assert(p.y >= 0); // world does not extend below y=0
    assert(p.y < activeRegionExtent.y); // world does not extend above y=activeRegionExtent.y
    
    GSChunkVoxelData *v = [gridVoxelData objectAtPoint:p objectFactory:^id(GSVector3 minP) {
        return [[[GSChunkVoxelData alloc] initWithMinP:minP
                                                folder:folder
                                        groupForSaving:groupForSaving
                                        chunkTaskQueue:chunkTaskQueue
                                             generator:^(GSVector3 a, voxel_t *voxel) {
                                                 generateTerrainVoxel(seed, terrainHeight, a, voxel);
                                             }] autorelease];
    }];
    
    return v;
}


+ (NSURL *)newWorldSaveFolderURLWithSeed:(unsigned)seed
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *folder = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    
    folder = [folder stringByAppendingPathComponent:@"GutsyStorm"];
    folder = [folder stringByAppendingPathComponent:@"save"];
    folder = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",seed]];
    NSLog(@"ChunkStore will save chunks to folder: %@", folder);
    
    if(![[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL]) {
        NSLog(@"Failed to create save folder: %@", folder);
    }
    
    NSURL *url = [[NSURL alloc] initFileURLWithPath:folder isDirectory:YES];
    
    if(![url checkResourceIsReachableAndReturnError:NULL]) {
        NSLog(@"ChunkStore's Save folder not reachable: %@", folder);
    }
    
    return url;
}


- (void)updateChunkVisibilityForActiveRegion
{
    //CFAbsoluteTime timeStart = CFAbsoluteTimeGetCurrent();

    GSFrustum *frustum = [camera frustum];
    
    [activeRegion enumerateActiveChunkWithBlock:^(GSChunkGeometryData *geometry) {
        if(geometry) {
            geometry->visible = (GS_FRUSTUM_OUTSIDE != [frustum boxInFrustumWithBoxVertices:geometry->corners]);
        }
    }];
    
    //CFAbsoluteTime timeEnd = CFAbsoluteTimeGetCurrent();
    //NSLog(@"Finished chunk visibility checks. It took %.3fs", timeEnd - timeStart);
}


- (void)updateActiveChunksWithCameraModifiedFlags:(unsigned)flags
{
    // If the camera moved then recalculate the set of active chunks.
    if(flags & CAMERA_MOVED) {
        // We can avoid a lot of work if the camera hasn't moved enough to add/remove any chunks in the active region.
        chunk_id_t newCenterChunkID = [GSChunkData chunkIDWithChunkMinCorner:[GSChunkData minCornerForChunkAtPoint:[camera cameraEye]]];
        
        if(![oldCenterChunkID isEqual:newCenterChunkID]) {
            [activeRegion updateWithSorting:NO camera:camera chunkProducer:^GSChunkGeometryData *(GSVector3 p) {
                return [self chunkGeometryAtPoint:p];
            }];

            // Now save this chunk ID for comparison next update.
            [oldCenterChunkID release];
            oldCenterChunkID = newCenterChunkID;
            [oldCenterChunkID retain];
        }
    }
    
    // If the camera moved or turned then recalculate chunk visibility.
    if((flags & CAMERA_TURNED) || (flags & CAMERA_MOVED)) {
        OSAtomicCompareAndSwapIntBarrier(0, 1, &needsChunkVisibilityUpdate);
    }
}

@end


// Return a value between -1 and +1 so that a line through the y-axis maps to a smooth gradient of values from -1 to +1.
static float groundGradient(float terrainHeight, GSVector3 p)
{
    const float y = p.y;
    
    if(y < 0.0) {
        return -1;
    } else if(y > terrainHeight) {
        return +1;
    } else {
        return 2.0*(y/terrainHeight) - 1.0;
    }
}


// Generates a voxel for the specified point in space. Returns that voxel in `outVoxel'.
static void generateTerrainVoxel(unsigned seed, float terrainHeight, GSVector3 p, voxel_t *outVoxel)
{
    static dispatch_once_t onceToken;
    static GSNoise *noiseSource0;
    static GSNoise *noiseSource1;
    
    BOOL groundLayer = NO;
    BOOL floatingMountain = NO;
    
    assert(outVoxel);
    
    dispatch_once(&onceToken, ^{
        noiseSource0 = [[GSNoise alloc] initWithSeed:seed];
        noiseSource1 = [[GSNoise alloc] initWithSeed:seed+1];
    });
    
    // Normal rolling hills
    {
        const float freqScale = 0.025;
        float n = [noiseSource0 noiseAtPointWithFourOctaves:GSVector3_Scale(p, freqScale)];
        float turbScaleX = 2.0;
        float turbScaleY = terrainHeight / 2.0;
        float yFreq = turbScaleX * ((n+1) / 2.0);
        float t = turbScaleY * [noiseSource1 noiseAtPoint:GSVector3_Make(p.x*freqScale, p.y*yFreq*freqScale, p.z*freqScale)];
        groundLayer = groundGradient(terrainHeight, GSVector3_Make(p.x, p.y + t, p.z)) <= 0;
    }
    
    // Giant floating mountain
    {
        /* The floating mountain is generated by starting with a sphere and applying turbulence to the surface.
         * The upper hemisphere is also squashed to make the top flatter.
         */
        
        GSVector3 mountainCenter = GSVector3_Make(50, 50, 80);
        GSVector3 toMountainCenter = GSVector3_Sub(mountainCenter, p);
        float distance = GSVector3_Length(toMountainCenter);
        float radius = 30.0;
        
        // Apply turbulence to the surface of the mountain.
        float freqScale = 0.70;
        float turbScale = 15.0;
        
        // Avoid generating noise when too far away from the center to matter.
        if(distance > 2.0*radius) {
            floatingMountain = NO;
        } else {
            // Convert the point into spherical coordinates relative to the center of the mountain.
            float azimuthalAngle = acosf(toMountainCenter.z / distance);
            float polarAngle = atan2f(toMountainCenter.y, toMountainCenter.x);
            
            float t = turbScale * [noiseSource0 noiseAtPointWithFourOctaves:GSVector3_Make(azimuthalAngle * freqScale,
                                                                                              polarAngle * freqScale, 0.0)];
            
            // Flatten the top.
            if(p.y > mountainCenter.y) {
                radius -= (p.y - mountainCenter.y) * 3;
            }
            
            floatingMountain = (distance+t) < radius;
        }
    }
    
    *outVoxel = (groundLayer || floatingMountain) ? ~VOXEL_EMPTY : VOXEL_EMPTY;
}