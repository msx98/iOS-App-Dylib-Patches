#ifndef APP_DYLIB_PATCHES_UTILS_H
#define APP_DYLIB_PATCHES_UTILS_H

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <sys/stat.h>

#define CONCAT_MACRO(A, B) A##B

NSString *getActualContainerPath() {
    return [[[[NSHomeDirectory() stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

#include "foundation.m"
#include "logger.m"

#endif
