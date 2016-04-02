//
//  GSGridVBOs.m
//  GutsyStorm
//
//  Created by Andrew Fox on 3/25/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSGrid.h"
#import "GSChunkVBOs.h"
#import "GSGridVBOs.h"

@implementation GSGridVBOs

- (instancetype)initWithName:(NSString *)name factory:(GSGridItemFactory)factory
{
    if (self = [super initWithName:name factory:factory]) {
        self.invalidationNotification = ^{ /* do nothing */ };
    }
    return self;
}

- (void)willInvalidateItem:(NSObject <GSGridItem> *)item atPoint:(vector_float3)p
{
    self.invalidationNotification();
}

@end
