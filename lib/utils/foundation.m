#ifndef APP_DYLIB_PATCHES_FOUNDATION_H
#define APP_DYLIB_PATCHES_FOUNDATION_H

#import <Foundation/Foundation.h>

#define MACRO_LITERAL_STRINGIFY(x) #x

#ifndef CONCAT_MACRO
#define CONCAT_MACRO(A, B) A##B
#endif

#import <arpa/inet.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sys/socket.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "logger.m"
#import "../fishhook/fishhook.h"
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
        struct rebinding bindings[] = {{"_os_log_impl", _hook_os_log_impl, (void **)&_original_os_log_impl}};
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