#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "utils.h"

// UIDevice hooks

static UIUserInterfaceIdiom hooked_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPhone;
}

static NSString *hooked_model(id self, SEL _cmd) {
    return @"iPhone";
}

static NSString *hooked_localizedModel(id self, SEL _cmd) {
    return @"iPhone";
}

// UITraitCollection hook

static UIUserInterfaceIdiom hooked_trait_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPhone;
}

void init() {
    debug_print(@"[Force-iPhone] Installing hooks");

    Class deviceCls = [UIDevice class];
    if (deviceCls) {
        Method m;

        m = class_getInstanceMethod(deviceCls, @selector(userInterfaceIdiom));
        if (m) {
            method_setImplementation(m, (IMP)hooked_userInterfaceIdiom);
            debug_print(@"[Force-iPhone] Hooked UIDevice.userInterfaceIdiom");
        }

        m = class_getInstanceMethod(deviceCls, @selector(model));
        if (m) {
            method_setImplementation(m, (IMP)hooked_model);
            debug_print(@"[Force-iPhone] Hooked UIDevice.model");
        }

        m = class_getInstanceMethod(deviceCls, @selector(localizedModel));
        if (m) {
            method_setImplementation(m, (IMP)hooked_localizedModel);
            debug_print(@"[Force-iPhone] Hooked UIDevice.localizedModel");
        }
    } else {
        debug_print(@"[Force-iPhone] UIDevice class not found");
    }

    Class traitCls = [UITraitCollection class];
    if (traitCls) {
        Method m = class_getInstanceMethod(traitCls, @selector(userInterfaceIdiom));
        if (m) {
            method_setImplementation(m, (IMP)hooked_trait_userInterfaceIdiom);
            debug_print(@"[Force-iPhone] Hooked UITraitCollection.userInterfaceIdiom");
        }
    } else {
        debug_print(@"[Force-iPhone] UITraitCollection class not found");
    }

    debug_print(@"[Force-iPhone] Done");
}
