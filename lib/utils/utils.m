#ifndef APP_DYLIB_PATCHES_UTILS_H
#define APP_DYLIB_PATCHES_UTILS_H

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "fishhook/fishhook.h"

static NSString *getActualContainerPath();
static NSBundle *getActualHostBundle();
static NSString *getDocumentsPath();
static NSString *getControllerIP();

static NSString *DOCUMENTS_PATH = nil;
static NSString *CONTAINER_PATH = nil;
static NSBundle *HOST_BUNDLE = nil;
static NSString *CONTROLLER_IP = nil;

#define CONCAT_MACRO(A, B) A##B
#define MACRO_LITERAL_STRINGIFY(x) #x

typedef struct NetworkLogger {
  char name[64];
  int sock;
  struct sockaddr_in addr;
  dispatch_queue_t send_queue;
} NetworkLogger;

static NetworkLogger logger; // Global instance

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

static inline void network_logger_init(NetworkLogger *l, const char *name,
                                       uint16_t port) {
  os_log(OS_LOG_DEFAULT, "Initializing NetworkLogger: %{public}s", name);
  memset(l, 0, sizeof(*l));
  strlcpy(l->name, name, sizeof(l->name));
  NSString* controllerIP = getControllerIP();
  if (controllerIP != nil) {
    l->sock = socket(AF_INET, SOCK_DGRAM, 0);
    l->addr.sin_family = AF_INET;
    l->addr.sin_port = htons(port);
    inet_pton(AF_INET, controllerIP.UTF8String, &l->addr.sin_addr);
    l->send_queue = dispatch_queue_create("com.networklogger.send", DISPATCH_QUEUE_SERIAL);
  }
}

static NSString *logFormat = @"[%s] %@";

static inline NSString* network_logger_print(NetworkLogger *l, NSString *message) {
  NSString *dataString = [NSString stringWithFormat:logFormat, l->name, message];
  os_log(OS_LOG_DEFAULT, "%s", dataString.UTF8String);
  //if (l -> sock != 0) {
  if ((CONTROLLER_IP != nil) && (l->sock != 0)) {
    dispatch_async(l->send_queue, ^{
      NSData *data = [[dataString stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
      sendto(l->sock, data.bytes, data.length, 0, (struct sockaddr *)&(l->addr), sizeof(l->addr));
    });
  }
  return dataString;
}

static inline void network_logger_destroy(NetworkLogger *l) {
  if (l->sock >= 0) {
    close(l->sock);
    l->sock = -1;
  }
  if (l->send_queue) {
    dispatch_release(l->send_queue);
    l->send_queue = NULL;
  }
}

#define debug_print(fmt, ...) do {                                                      \
    network_logger_print(&logger, [NSString stringWithFormat:(fmt), ##__VA_ARGS__]);    \
  } while (0);

#define INIT_LOGGER(name)                                                      \
  do {                                                                         \
    network_logger_init(&logger, name, 8889);                                  \
    debug_print(@"Logger initialized");                                        \
  } while (0);


#define CALLED_VIA_LOAD_DYLIB_ENV_FLAG "CALLED_VIA_LOAD_DYLIB"

typedef void (*_os_log_impl_t)(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
static _os_log_impl_t _original_os_log_impl = NULL;

static void _hook_os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
    if (_original_os_log_impl) {
        _original_os_log_impl(dso, log, type, format, buf, size);
    }
    debug_print(@"[os_log] %s", format);
}

static void* LOAD_DYLIB(const char* path) {
    setenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG, "1", 1);
    void* handle = dlopen(path, RTLD_NOW|RTLD_GLOBAL);
    unsetenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG);
    if (!handle) {
        debug_print(@"Failed to load dylib at path: %s, error: %s", path, dlerror());
        exit(1);
    }
    debug_print(@"Successfully loaded dylib at path: %s", path);
    void *mainFunc = dlsym(handle, "__init__");
    if (!mainFunc) {
        debug_print(@"Failed to find __init__ in dylib at path: %s, error: %s", path, dlerror());
        return handle;
    }
    debug_print(@"Successfully found __init__ in dylib at path: %s", path);
    Dl_info info;
    if (dladdr(mainFunc, &info)) {
        const struct mach_header *mh = (const struct mach_header *)info.dli_fbase;
        intptr_t slide = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            if (_dyld_get_image_header(i) == mh) {
                slide = _dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
        struct rebinding bindings[] = {{"_os_log_impl", (void *)_hook_os_log_impl, (void **)&_original_os_log_impl}};
        rebind_symbols_image((void *)mh, slide, bindings, 1);
    }
    ((void(*)(NetworkLogger))(mainFunc))(logger);
    return handle;
}

#define INITIALIZE(NAME) \
    void __init__(NetworkLogger logger_) \
    {                                                                             \
        logger.sock = logger_.sock;                                               \
        debug_print(@"Initializer " @NAME @" called. %p, %p", &logger, &logger_); \
        init();                                                                 \
    }                                                                             \
    __attribute__((constructor)) \
    static void __on_dlopen__() { \
        if (getenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG) == NULL) { \
            INIT_LOGGER(NAME); \
            init(); \
        } else { \
            unsetenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG); \
        } \
    }


#endif
