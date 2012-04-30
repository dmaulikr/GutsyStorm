//
//  GSChunkVoxelData.h
//  GutsyStorm
//
//  Created by Andrew Fox on 4/17/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSChunkData.h"
#import "GSIntegerVector3.h"
#import "GSReaderWriterLock.h"


#define CHUNK_NEIGHBOR_POS_X_NEG_Z  (0)
#define CHUNK_NEIGHBOR_POS_X_ZER_Z  (1)
#define CHUNK_NEIGHBOR_POS_X_POS_Z  (2)
#define CHUNK_NEIGHBOR_NEG_X_NEG_Z  (3)
#define CHUNK_NEIGHBOR_NEG_X_ZER_Z  (4)
#define CHUNK_NEIGHBOR_NEG_X_POS_Z  (5)
#define CHUNK_NEIGHBOR_ZER_X_NEG_Z  (6)
#define CHUNK_NEIGHBOR_ZER_X_POS_Z  (7)
#define CHUNK_NEIGHBOR_CENTER       (8)
#define CHUNK_NUM_NEIGHBORS         (9)

#define CHUNK_LIGHTING_MAX (15)


typedef struct
{
	BOOL empty;   // YES, if the voxel is never drawn.
	BOOL outside; // YES, if the voxel is exposed to the sky from directly above.
} voxel_t;


typedef struct
{
	/* Each face has four vertices, and we need a brightness factor for
     * all 24 of these vertices.
     */
    
    float top[4];
    float bottom[4];
    float left[4];
    float right[4];
    float front[4];
    float back[4];
} block_lighting_t;


@interface GSChunkVoxelData : GSChunkData
{
 @public
    GSReaderWriterLock *lockVoxelData;
	voxel_t *voxelData;
	
	GSReaderWriterLock *lockSunlight;
	int *sunlight;
	
	NSConditionLock *lockAmbientOcclusion;
	block_lighting_t *ambientOcclusion;
}

+ (NSString *)fileNameForVoxelDataFromMinP:(GSVector3)minP;

- (id)initWithSeed:(unsigned)seed
              minP:(GSVector3)minP
     terrainHeight:(float)terrainHeight
			folder:(NSURL *)folder;

- (void)updateLightingWithNeighbors:(GSChunkVoxelData **)neighbors;

// Assumes the caller is already holding "lockVoxelData".
- (voxel_t)getVoxelAtPoint:(GSIntegerVector3)chunkLocalP;
- (voxel_t *)getPointerToVoxelAtPoint:(GSIntegerVector3)chunkLocalP;

// Assumes the caller is already holding "lockSunlight" on all neighbors.
- (block_lighting_t)getSunlightAtPoint:(GSIntegerVector3)p neighbors:(GSChunkVoxelData **)voxels;

// Assumes the caller is already holding "lockAmbientOcclusion".
- (block_lighting_t)getAmbientOcclusionAtPoint:(GSIntegerVector3)p;

@end


// Assumes the caller is already holding "lockVoxelData" on all chunks in neighbors.
GSChunkVoxelData* getNeighborVoxelAtPoint(GSIntegerVector3 chunkLocalP,
										  GSChunkVoxelData **neighbors,
										  GSIntegerVector3 *outRelativeToNeighborP);


// Assumes the caller is already holding "lockVoxelData" on all chunks in neighbors.
BOOL isEmptyAtPoint(GSIntegerVector3 p, GSChunkVoxelData **neighbors);


void noAmbientOcclusion(block_lighting_t *ao);
