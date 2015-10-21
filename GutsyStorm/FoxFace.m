//
//  FoxFace.m
//  GutsyStorm
//
//  Created by Andrew Fox on 1/12/13.
//  Copyright (c) 2013-2015 Andrew Fox. All rights reserved.
//

#import "FoxTerrainBuffer.h" // for terrain_buffer_element_t, needed by FoxVoxel.h
#import "FoxVoxel.h" // for face_t, needed by FoxFace.h
#import "FoxFace.h"
#import "FoxVertex.h"

@implementation FoxFace

+ (NSArray<FoxVertex *> *)decomposeQuad:(NSArray<FoxVertex *> *)verticesIn
{
    NSParameterAssert(verticesIn);
    
    NSArray<FoxVertex *> *verticesOut = nil;
    NSUInteger count = verticesIn.count;
    
    assert(count == 4 || count == 3);
    
    if (count == 3) {
        verticesOut = verticesIn;
    } else {
        verticesOut = @[ verticesIn[0], verticesIn[1], verticesIn[2],
                         verticesIn[0], verticesIn[2], verticesIn[3] ];
    }
    
    return verticesOut;
}

+ (BOOL)determineEligibilityForOmission:(NSArray<FoxVertex *> *)vertices
{
    NSParameterAssert(vertices && vertices.count >= 3);

    // The face is eligible for omission if it fits exactly into a cube face. (i.e. unit area)
    vector_float3 a = [((FoxVertex *)[vertices objectAtIndex:0]) position];
    vector_float3 b = [((FoxVertex *)[vertices objectAtIndex:1]) position];
    vector_float3 c = [((FoxVertex *)[vertices objectAtIndex:2]) position];

    vector_float3 ba = b - a;
    vector_float3 bc = b - c;
    vector_float3 n1 = vector_cross(ba, bc);

    BOOL result = vector_equal(n1, vector_make(0, 0, -1)) ||
                  vector_equal(n1, vector_make(0, 0, +1)) ||
                  vector_equal(n1, vector_make(0, -1, 0)) ||
                  vector_equal(n1, vector_make(0, +1, 0)) ||
                  vector_equal(n1, vector_make(-1, 0, 0)) ||
                  vector_equal(n1, vector_make(+1, 0, 0));
    
    return result;
}

+ (FoxFace *)faceWithQuad:(NSArray<FoxVertex *> *)vertices correspondingCubeFace:(face_t)face
{
    NSParameterAssert(vertices && vertices.count == 4);
    NSArray<FoxVertex *> *triangleVertices = [self decomposeQuad:vertices];
    BOOL omittable = [self determineEligibilityForOmission:vertices];
    return [[FoxFace alloc] initWithVertices:triangleVertices
                      correspondingCubeFace:face
                        eligibleForOmission:omittable];
}

+ (FoxFace *)faceWithTri:(NSArray<FoxVertex *> *)vertices correspondingCubeFace:(face_t)face
{
    NSParameterAssert(vertices && vertices.count == 3);
    BOOL omittable = [self determineEligibilityForOmission:vertices];
    return [[FoxFace alloc] initWithVertices:vertices
                      correspondingCubeFace:face
                        eligibleForOmission:omittable];
}

- (instancetype)init
{
    @throw nil;
    return nil;
}

- (instancetype)initWithVertices:(NSArray<FoxVertex *> *)vertices
           correspondingCubeFace:(face_t)face
             eligibleForOmission:(BOOL)omittable
{
    NSParameterAssert(vertices);
    NSParameterAssert(face >= 0 && face < FACE_NUM_FACES);

    self = [super init];
    if (self) {
        _vertexList = vertices;
        _correspondingCubeFace = face;
        _eligibleForOmission = omittable;
    }

    return self;
}

@end