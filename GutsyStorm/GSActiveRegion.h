//
//  GSActiveRegion.h
//  GutsyStorm
//
//  Created by Andrew Fox on 9/14/12.
//  Copyright (c) 2012 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSChunkGeometryData.h"

@class GSCamera;
@class GSFrustum;


@interface GSActiveRegion : NSObject

@property (readonly, nonatomic) NSUInteger maxActiveChunks;

- (id)initWithActiveRegionExtent:(GLKVector3)activeRegionExtent;
- (void)updateWithCameraModifiedFlags:(unsigned)flags
                               camera:(GSCamera *)camera
                        chunkProducer:(GSChunkGeometryData * (^)(GLKVector3 p))chunkProducer;
- (void)drawWithVBOGenerationLimit:(NSUInteger)limit;
- (void)enumerateActiveChunkWithBlock:(void (^)(GSChunkGeometryData *))block;
- (NSArray *)pointsListSortedByDistFromCamera:(GSCamera *)camera unsortedList:(NSMutableArray *)unsortedPoints;
- (NSArray *)chunksListSortedByDistFromCamera:(GSCamera *)camera unsortedList:(NSMutableArray *)unsortedChunks;
- (void)enumeratePointsInActiveRegionNearCamera:(GSCamera *)camera usingBlock:(void (^)(GLKVector3 p))myBlock;

@end
