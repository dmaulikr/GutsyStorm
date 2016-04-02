//
//  GSOpenGLView.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/16/12.
//  Copyright © 2012-2016 Andrew Fox. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@class GSOpenGLView;


@protocol GSOpenGLViewDelegate <NSObject>

- (void)openGLView:(nonnull GSOpenGLView *)view drawableSizeWillChange:(CGSize)size;
- (void)drawInOpenGLView:(nonnull GSOpenGLView *)view;

@end


@interface GSOpenGLView : NSOpenGLView

@property (nonatomic, weak, nullable) id<GSOpenGLViewDelegate> delegate;

- (void)shutdown;

@end