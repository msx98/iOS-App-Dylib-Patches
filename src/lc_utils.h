#ifndef APP_DYLIB_PATCHES_LC_UTILS_H
#define APP_DYLIB_PATCHES_LC_UTILS_H

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <os/log.h>

#define CONCAT_MACRO(A, B) A##B
#define MACRO_LITERAL_STRINGIFY(x) #x

#define BREAKPOINT if (true) { \
    debug_print(@"[BREAKPOINT] [%s:%d] Pause and run 'j +1' in lldb to continue execution.", __FILE__, __LINE__+1); \
    sleep(3600); \
}

static NSString *getActualContainerPath();
static NSBundle *getActualHostBundle();
static NSString *getDocumentsPath();
static NSString *getControllerIP();

static NSString *DOCUMENTS_PATH = nil;
static NSString *CONTAINER_PATH = nil;
static NSBundle *HOST_BUNDLE = nil;
static NSString *CONTROLLER_IP = nil;

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
    NSBundle * __autoreleasing *lcMainBundlePtr =
        (NSBundle * __autoreleasing *)dlsym(RTLD_DEFAULT, "lcMainBundle");
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
        stringByAppendingPathComponent:@"NetworkTweaks/ip.txt"];
    BOOL file_exists =
        [[NSFileManager defaultManager] fileExistsAtPath:ipFilePath];
    if (!file_exists) {
      os_log(OS_LOG_DEFAULT, "Controller IP file not found: %{public}s",
             ipFilePath.UTF8String);
      return nil;
    }
    CONTROLLER_IP = [NSString stringWithContentsOfFile:ipFilePath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
  }
  return CONTROLLER_IP;
}

#endif
