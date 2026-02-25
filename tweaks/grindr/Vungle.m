#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * vungleHide.m
 * Immediate override of VungleAds initialization and state.
 */

// 1. Mock for + (void)initWithAppId:completion:
static void mock_vungle_init(id self, SEL _cmd, NSString *appId, void (^completion)(NSError *)) {
    os_log(OS_LOG_DEFAULT, "[VungleHide] Intercepted init. Firing completion(nil) immediately.");
    if (completion) {
        completion(nil); // Report success
    }
}

// 2. Mock for + (BOOL)isInitialized
static BOOL mock_isInitialized(id self, SEL _cmd) {
    // We always return YES so the app thinks the SDK is ready
    return NO;
}

__attribute__((constructor))
static void init_VungleNuclearOption() {
    // We use a small loop to wait for the class if it's in a dynamic framework
    // but we don't 'dispatch_after' to keep it as "immediate" as possible.
    int attempts = 0;
    Class vungleCls = objc_getClass("VungleAdsSDK.VungleAds");
    
    while (!vungleCls && attempts < 100) {
        vungleCls = objc_getClass("VungleAds");
        if (!vungleCls) {
            attempts++;
            usleep(10000); // Wait 10ms
        }
    }

    if (vungleCls) {
        Class metaCls = object_getClass(vungleCls);

        // --- Hook initWithAppId:completion: ---
        SEL initSel = sel_registerName("initWithAppId:completion:");
        Method mInit = class_getClassMethod(vungleCls, initSel);
        if (mInit) {
            class_replaceMethod(metaCls, initSel, (IMP)mock_vungle_init, "v@:@@?");
        }

        // --- Hook isInitialized ---
        SEL stateSel = sel_registerName("isInitialized");
        Method mState = class_getClassMethod(vungleCls, stateSel);
        if (mState) {
            class_replaceMethod(metaCls, stateSel, (IMP)mock_isInitialized, "B@:");
        }

        os_log(OS_LOG_DEFAULT, "[VungleHide] VungleAds is now fully mocked and 'Always Ready'.");
    } else {
        os_log(OS_LOG_DEFAULT, "[VungleHide] Failed to find VungleAds class after 1 second.");
    }
}
