#ifndef IOS_APP_DYLIB_PATCHES_UTILS_H
#define IOS_APP_DYLIB_PATCHES_UTILS_H

#import <Foundation/Foundation.h>

static NSString *getActualContainerPath();
static NSBundle *getActualHostBundle();
static NSString *getDocumentsPath();
static NSString *getControllerIP();

static NSString *DOCUMENTS_PATH = nil;
static NSString *CONTAINER_PATH = nil;
static NSBundle *HOST_BUNDLE = nil;
static NSString *CONTROLLER_IP = nil;

#endif