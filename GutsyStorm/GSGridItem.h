//
//  GSGridItem.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/12/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import <simd/vector.h>


struct GSStopwatchTraceState;


@protocol GSGridItem <NSCopying>

@required

/* The minimum corner of the item, which is a rectangular prism (box). */
@property (readonly, nonatomic) vector_float3 minP;

/* The cost of the item for use in grids which enforce cost limits. */
@property (readonly, nonatomic) NSUInteger cost;

@optional

/* Message indicates the grid item is about to be evicted from the grid cache.
 * The item should clean up. Some items may want to save themselves to disk to speed up regeneration later.
 */
- (void)itemWillBeEvicted;

/* Message indicates the grid item is about to be invalidated.
 * The item should take care to clean up and remove any on-disk cache files as they would not be valid.
 */
- (void)itemWillBeInvalidated;

@end

/* This block defines a factory to generate new grid item objects given only the unique minP of the item. */
typedef NSObject<GSGridItem> * (^GSGridItemFactory)(vector_float3 minP);