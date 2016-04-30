//
//  GSGridSlot.m
//  GutsyStorm
//
//  Created by Andrew Fox on 4/27/16.
//  Copyright © 2016 Andrew Fox. All rights reserved.
//

#import "GSGridSlot.h"
#import "GSReaderWriterLock.h"

@implementation GSGridSlot
{
    NSObject<GSGridItem> *_item;
}

- (nonnull instancetype)init
{
    @throw nil;
}

- (nonnull instancetype)initWithMinP:(vector_float3)mp
{
    if (self = [super init]) {
        _minP = mp;
        _lock = [[GSReaderWriterLock alloc] init];
        _lock.name = [NSString stringWithFormat:@"slot(%.0f,%.0f,%.0f)", mp.x, mp.y, mp.z];
        _item = nil;
    }
    return self;
}

- (void)setItem:(NSObject<GSGridItem> *)item
{
    if (![_lock holdingWriteLock]) {
        [NSException raise:NSInternalInconsistencyException format:@"Must be holding the write lock to set the item."];
    }
    
    if (item != _item) {
        _item = item;
    }
}

@end
