#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

static IMP orig_setUrl = NULL;
static IMP orig_setURL = NULL;

static void hooked_setUrl(id self, SEL _cmd, NSString *url) {
    debug_print(@"[STWebpageController] setUrl: %@", url);
    if (orig_setUrl) ((void (*)(id, SEL, NSString *))orig_setUrl)(self, _cmd, url);
}

static void hooked_setURL(id self, SEL _cmd, id url) {
    debug_print(@"[STWebpageController] setURL: %@", url);
    if (orig_setURL) ((void (*)(id, SEL, id))orig_setURL)(self, _cmd, url);
}

static void init() {
    debug_print(@"Initialized");

    Class cls = objc_getClass("STWebpageController");
    if (!cls) {
        debug_print(@"STWebpageController not found");
        return;
    }
    debug_print(@"Found STWebpageController");

    Method m;

    m = class_getInstanceMethod(cls, @selector(setUrl:));
    if (m) {
        orig_setUrl = method_setImplementation(m, (IMP)hooked_setUrl);
        debug_print(@"Hooked setUrl:");
    }

    m = class_getInstanceMethod(cls, @selector(setURL:));
    if (m) {
        orig_setURL = method_setImplementation(m, (IMP)hooked_setURL);
        debug_print(@"Hooked setURL:");
    }

    if (!orig_setUrl && !orig_setURL) {
        debug_print(@"No URL setter found on STWebpageController — dumping methods:");
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            debug_print(@"  - %s", sel_getName(method_getName(methods[i])));
        }
        free(methods);
    }
}

INITIALIZE("WebRecorder")