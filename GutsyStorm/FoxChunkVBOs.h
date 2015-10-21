//
//  FoxChunkVBOs.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/17/13.
//  Copyright (c) 2013-2015 Andrew Fox. All rights reserved.
//

@class FoxChunkGeometryData;

@interface FoxChunkVBOs : NSObject <FoxGridItem>

- (instancetype)initWithChunkGeometry:(FoxChunkGeometryData *)geometry
                            glContext:(NSOpenGLContext *)glContext;

// Assumes the caller has already locked the context on the current thread.
- (void)draw;

@end