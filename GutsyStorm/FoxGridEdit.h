//
//  FoxGridEdit.h
//  GutsyStorm
//
//  Created by Andrew Fox on 10/10/15.
//  Copyright © 2015 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <simd/simd.h>

@interface FoxGridEdit : NSObject

@property (nonatomic, strong) id _Nullable originalObject;
@property (nonatomic, strong) id _Nullable modifiedObject;
@property (nonatomic, assign) vector_float3 pos;

- (nullable instancetype)initWithOriginalItem:(id _Nullable)item
                                 modifiedItem:(id _Nullable)replacement
                                          pos:(vector_float3)p;

@end
