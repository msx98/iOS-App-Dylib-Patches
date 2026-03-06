#ifndef APP_DYLIB_PATCHES_DYLIB_LOADER_H
#define APP_DYLIB_PATCHES_DYLIB_LOADER_H

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <os/log.h>

#import "submodules/fishhook/fishhook.h"
#import "logger.h"

#define CALLED_VIA_LOAD_DYLIB_ENV_FLAG "CALLED_VIA_LOAD_DYLIB"

typedef void (*_os_log_impl_t)(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
static _os_log_impl_t _original_os_log_impl = NULL;

static void _hook_os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) {
    if (_original_os_log_impl) {
        _original_os_log_impl(dso, log, type, format, buf, size);
    }
    debug_print(@"[oss_log] %s", format);
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

#endif
