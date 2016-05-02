//
//  GSChunkStore.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/24/12.
//  Copyright © 2012-2016 Andrew Fox. All rights reserved.
//

#import "GSChunkVoxelData.h"
#import "GSTerrainBuffer.h"


@class GSGrid;
@class GSCamera;
@class GSShader;
@class GSTerrainJournal;
@class GSChunkVAO;
@class GSBoxedVector;
@class GSTerrainGenerator;
@class GSChunkGeometryData;
@class GSChunkSunlightData;
@class GSChunkVoxelData;


@interface GSTerrainChunkStore : NSObject

@property (nonatomic, nonnull, readonly) GSGrid *gridVAO;
@property (nonatomic, nonnull, readonly) GSGrid *gridGeometryData;
@property (nonatomic, nonnull, readonly) GSGrid *gridSunlightData;
@property (nonatomic, nonnull, readonly) GSGrid *gridVoxelData;

- (nonnull instancetype)initWithJournal:(nonnull GSTerrainJournal *)journal
                                 camera:(nonnull GSCamera *)camera
                          terrainShader:(nonnull GSShader *)terrainShader
                              glContext:(nonnull NSOpenGLContext *)glContext
                              generator:(nonnull GSTerrainGenerator *)generator;

/* Assumes the caller has already locked the GL context or
 * otherwise ensures no concurrent GL calls will be made.
 */
- (void)drawActiveChunks;

- (void)updateWithCameraModifiedFlags:(unsigned)cameraModifiedFlags;

/* Try to get the Vertex Array Object for the specified point in space.
 * Returns nil when it's not possible to get the VAO without blocking on a lock.
 */
- (nullable GSChunkVAO *)tryToGetVaoAtPoint:(vector_float3)pos;

/* Try to get the Vertex Array Object for the specified point in space.
 * Returns nil when it's not possible to get the VAO without blocking on a lock.
 * If the `createIfMissing' flag is set then the VAO is created if the slot was empty. This can take time.
 */
- (nullable GSChunkVAO *)nonBlockingVaoAtPoint:(nonnull GSBoxedVector *)p createIfMissing:(BOOL)createIfMissing;

- (void)setBlock:(GSVoxel)block atPoint:(vector_float3)pos addToJournal:(BOOL)addToJournal;

- (nonnull GSChunkGeometryData *)chunkGeometryAtPoint:(vector_float3)p;
- (nonnull GSChunkSunlightData *)chunkSunlightAtPoint:(vector_float3)p;
- (nonnull GSChunkVoxelData *)chunkVoxelsAtPoint:(vector_float3)p;

/* Notify the chunk store object that the system has come under memory pressure. */
- (void)memoryPressure:(dispatch_source_memorypressure_flags_t)status;

- (void)printInfo;

/* Clean-up in preparation for destroying the terrain object.
 * For example, synchronize with the disk one last time and resources.
 */
- (void)shutdown;

@end
