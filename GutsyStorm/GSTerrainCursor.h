//
//  GSTerrainCursor.h
//  GutsyStorm
//
//  Created by Andrew Fox on 10/28/12.
//  Copyright © 2012-2016 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSChunkStore.h"
#import "GSCube.h"

@class GSShader;
@class GSCamera;

@interface GSTerrainCursor : NSObject

@property (nonatomic, assign) BOOL cursorIsActive;
@property (nonatomic, assign) vector_float3 cursorPos;
@property (nonatomic, assign) vector_float3 cursorPlacePos;

- (nonnull instancetype)init NS_UNAVAILABLE;
- (nonnull instancetype)initWithContext:(nonnull NSOpenGLContext *)context
                                  shader:(nonnull GSShader *)shader NS_DESIGNATED_INITIALIZER;
- (void)drawWithCamera:(nonnull GSCamera *)camera;

@end
