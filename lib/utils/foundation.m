#ifndef APP_DYLIB_PATCHES_FOUNDATION_H
#define APP_DYLIB_PATCHES_FOUNDATION_H

#define MACRO_LITERAL_STRINGIFY(x) #x

#ifndef CONCAT_MACRO
#define CONCAT_MACRO(A, B) A##B
#endif

// load dlsym and obtain main
#define LOAD_DYLIB(PATH)                                                                                   \
    do                                                                                                     \
    {                                                                                                      \
        void *handle = dlopen(PATH, RTLD_NOW | RTLD_GLOBAL);                                               \
        if (!handle)                                                                                       \
        {                                                                                                  \
            debug_print(@"Failed to load dylib at path: %s, error: %s", PATH, dlerror());                  \
        }                                                                                                  \
        else                                                                                               \
        {                                                                                                  \
            debug_print(@"Successfully loaded dylib at path: %s", PATH);                                   \
        }                                                                                                  \
        void *mainFunc = dlsym(handle, "onInit_");                                                         \
        if (!mainFunc)                                                                                     \
        {                                                                                                  \
            debug_print(@"Failed to find main function in dylib at path: %s, error: %s", PATH, dlerror()); \
        }                                                                                                  \
        else                                                                                               \
        {                                                                                                  \
            debug_print(@"Successfully found main function in dylib at path: %s", PATH);                   \
        }                                                                                                  \
        mainFunc(&logger);                                                                                 \
    } while (0);

#define INITIALIZE(NAME)                                                          \
    static void onLoad();                                                         \
    static void onInit();                                                         \
    static void onInit_(NetworkLogger logger_)                                    \
    {                                                                             \
        logger.sock = logger_.sock;                                               \
        debug_print(@"Initializer " @NAME @" called. %p, %p", &logger, &logger_); \
        onInit();                                                                 \
    }                                                                             \
    __attribute__((constructor)) static void onLoad_() { onLoad(); }

#endif