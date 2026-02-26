#ifndef APP_DYLIB_PATCHES_UTILS_H
#define APP_DYLIB_PATCHES_UTILS_H

#include "utils.h"
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

#define CONCAT_MACRO(A, B) A##B

NSString *getActualContainerPath() {
  if (CONTAINER_PATH == nil) {
    CONTAINER_PATH = [[[[NSHomeDirectory() stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent];
  }
  return CONTAINER_PATH;
}

NSBundle *getActualHostBundle() {
  // Get LiveContainer's original bundle via the lcMainBundle global
  // (set in LCBootstrap.m before mainBundle is swizzled to the guest app)
  if (HOST_BUNDLE == nil) {
    NSBundle **lcMainBundlePtr =
        (NSBundle **)dlsym(RTLD_DEFAULT, "lcMainBundle");
    NSBundle *hostBundle = lcMainBundlePtr ? *lcMainBundlePtr : nil;
    if (!hostBundle) {
      return nil;
    }

    // lcMainBundle may point to LiveProcess.appex — walk up to the main .app
    // LiveProcess.appex -> PlugIns/ -> LiveContainer.app
    NSString *bundlePath = hostBundle.bundlePath;
    if ([bundlePath.pathExtension isEqualToString:@"appex"]) {
      NSString *mainAppPath = [[bundlePath stringByDeletingLastPathComponent]
          stringByDeletingLastPathComponent];
      NSBundle *mainAppBundle = [NSBundle bundleWithPath:mainAppPath];
      if (mainAppBundle) {
        hostBundle = mainAppBundle;
      }
    }
    HOST_BUNDLE = hostBundle;
  }
  return HOST_BUNDLE;
}

static NSString *getDocumentsPath() {
  if (DOCUMENTS_PATH == nil) {
    DOCUMENTS_PATH =
        [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent];
  }
  return DOCUMENTS_PATH;
}

static NSString *getControllerIP() {
  // Read the controller IP from a file on disk (written by the
  // NetworkLoggerController Python script). This allows dynamic configuration
  // without hardcoding an IP in the tweak.
  if (!CONTROLLER_IP) {
    NSString *ipFilePath = [getDocumentsPath()
        stringByAppendingPathComponent:@"Tweaks/controller_ip.txt"];
    BOOL file_exists =
        [[NSFileManager defaultManager] fileExistsAtPath:ipFilePath];
    NSArray<NSString *> *subdirContents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:[getActualContainerPath()
                                      stringByDeletingLastPathComponent]
                            error:nil];
    CONTROLLER_IP = [NSString stringWithContentsOfFile:ipFilePath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
  }
  return CONTROLLER_IP;
}

#include "foundation.m"
#include "logger.m"

#endif
