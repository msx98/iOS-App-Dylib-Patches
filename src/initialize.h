#ifndef APP_DYLIB_PATCHES_INITIALIZE_H
#define APP_DYLIB_PATCHES_INITIALIZE_H

#import <Foundation/Foundation.h>
#import "logger.h"
#import "dylib_loader.h"

static char* __TWEAK_NAME__ = NULL;

// Pick explicit name if provided, else derive from __FILE__
#define _INIT_NAME_FROM_FILE() \
    strdup([[[[NSString stringWithUTF8String:__FILE__] lastPathComponent] stringByDeletingPathExtension] UTF8String])
#define _INIT_NAME_EXPLICIT(name) strdup(name)
#define _INIT_NAME_DISPATCH(_0, _1, N, ...) N
#define _INIT_NAME(...) _INIT_NAME_DISPATCH(_, ##__VA_ARGS__, _INIT_NAME_EXPLICIT, _INIT_NAME_FROM_FILE)(__VA_ARGS__)

void init();

static void __init__(NetworkLogger logger_) {
    // This will be overridden by the dylib loader if loaded via LOAD_DYLIB, otherwise it will be called directly by the constructor attribute below
    logger.sock = logger_.sock;
    debug_print(@"Initializer called for %s", __TWEAK_NAME__ ? __TWEAK_NAME__ : "unknown");
    init();
}

__attribute__((constructor))
static void __on_dlopen__() {
    if (__TWEAK_NAME__ == NULL) {
        __TWEAK_NAME__ = _INIT_NAME_FROM_FILE();
    }
    if (getenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG) == NULL) {
        INIT_LOGGER(__TWEAK_NAME__);
        init();
    } else {
        unsetenv(CALLED_VIA_LOAD_DYLIB_ENV_FLAG);
    }
}

#endif
