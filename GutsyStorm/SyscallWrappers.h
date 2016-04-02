//
//  SyscallWrappers.h
//  GutsyStorm
//
//  Created by Andrew Fox on 1/14/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>

void raiseExceptionForPOSIXError(int error, NSString * _Nonnull desc);

int Open(NSURL * _Nonnull url, int oflags, mode_t mode);
void Close(int fd);