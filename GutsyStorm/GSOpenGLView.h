//
//  GSOpenGLView.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/16/12.
//  Copyright © 2012 Andrew Fox. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "GSCamera.h"
#import "GLString.h"

@interface GSOpenGLView : NSOpenGLView
{
	GLuint vboCubeVerts;
	NSTimer* renderTimer;
	CFAbsoluteTime prevFrameTime;
	float cubeRotSpeed;
	float cubeRotY;
	NSMutableDictionary* keysDown;
	int32_t mouseDeltaX, mouseDeltaY;
	float mouseSensitivity;
	GSCamera* camera;
	GLString * testStringTex;
	NSMutableDictionary * stringAttribs; // attributes for string textures
}

- (void)drawHUD;
- (void)drawDebugCube;
- (void)setMouseAtCenter;
- (void)generateVBOForDebugCube;
- (void)enableVSync;
- (void)resetMouseInputSettings;
- (void)timerFired:(id)sender;
- (void)handleUserInput:(float)dt;

@end
