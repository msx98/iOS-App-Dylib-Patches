#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "utils.h"

// UIDevice hooks

static UIUserInterfaceIdiom hooked_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPad;
}

static NSString *hooked_model(id self, SEL _cmd) {
    return @"iPad";
}

static NSString *hooked_localizedModel(id self, SEL _cmd) {
    return @"iPad";
}

// UITraitCollection hook

static UIUserInterfaceIdiom hooked_trait_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPad;
}

void init() {
    debug_print(@"[Force-iPad] Installing hooks");

    Class deviceCls = [UIDevice class];
    if (deviceCls) {
        Method m;

        m = class_getInstanceMethod(deviceCls, @selector(userInterfaceIdiom));
        if (m) {
            method_setImplementation(m, (IMP)hooked_userInterfaceIdiom);
            debug_print(@"[Force-iPad] Hooked UIDevice.userInterfaceIdiom");
        }

        m = class_getInstanceMethod(deviceCls, @selector(model));
        if (m) {
            method_setImplementation(m, (IMP)hooked_model);
            debug_print(@"[Force-iPad] Hooked UIDevice.model");
        }

        m = class_getInstanceMethod(deviceCls, @selector(localizedModel));
        if (m) {
            method_setImplementation(m, (IMP)hooked_localizedModel);
            debug_print(@"[Force-iPad] Hooked UIDevice.localizedModel");
        }
    } else {
        debug_print(@"[Force-iPad] UIDevice class not found");
    }

    Class traitCls = [UITraitCollection class];
    if (traitCls) {
        Method m = class_getInstanceMethod(traitCls, @selector(userInterfaceIdiom));
        if (m) {
            method_setImplementation(m, (IMP)hooked_trait_userInterfaceIdiom);
            debug_print(@"[Force-iPad] Hooked UITraitCollection.userInterfaceIdiom");
        }
    } else {
        debug_print(@"[Force-iPad] UITraitCollection class not found");
    }

    debug_print(@"[Force-iPad] Done");
}
