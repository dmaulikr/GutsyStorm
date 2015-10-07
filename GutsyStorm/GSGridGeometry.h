//
//  GSGridGeometry.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/19/13.
//  Copyright (c) 2013 Andrew Fox. All rights reserved.
//

@interface GSGridGeometry : GSGrid

- (instancetype)initWithName:(NSString *)name
                 cacheFolder:(NSURL *)folder
                     factory:(grid_item_factory_t)factory;

@end