#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * applovinFix.m
 * Prevents "No SDK provided" crash by providing a neutered ALSdk instance.
 */

// --- 1. The Mock Initializer ---
// v@:@@? (void, self, _cmd, config, block)
static void swizzled_init(id self, SEL _cmd, id config, void (^block)(id)) {
    os_log(OS_LOG_DEFAULT, "[AppLovinFix] Neutralized SDK init call. Firing fake success.");
    if (block) {
        // We fire the block with nil (or a dummy config) so the app thinks it's ready.
        block(nil); 
    }
}

// --- 2. The Mock Ad Loader ---
// Prevents MARewardedAd and MAInterstitialAd from actually hitting the network.
static void swizzled_loadAd(id self, SEL _cmd) {
    os_log(OS_LOG_DEFAULT, "[AppLovinFix] Blocked loadAd call for %{public}s", 
           [NSStringFromClass([self class]) UTF8String]);
}

__attribute__((constructor))
static void init_AppLovinGhost() {
    // We wait briefly to ensure the AppLovin classes are mapped
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        Class sdkCls = objc_getClass("ALSdk");
        if (sdkCls) {
            // A. Neutralize the Actual Init Method
            SEL initSel = sel_registerName("initializeWithConfiguration:completionHandler:");
            Method mInit = class_getClassMethod(sdkCls, initSel);
            if (mInit) {
                class_replaceMethod(object_getClass(sdkCls), initSel, (IMP)swizzled_init, "v@:@@?");
            }

            // B. Neutralize standard loadAd methods across all MAX formats
            NSArray *adClasses = @[@"MARewardedAd", @"MAInterstitialAd", @"MAAdView"];
            for (NSString *name in adClasses) {
                Class cls = objc_getClass([name UTF8String]);
                if (cls) {
                    SEL loadSel = sel_registerName("loadAd");
                    Method mLoad = class_getInstanceMethod(cls, loadSel);
                    if (mLoad) {
                        class_replaceMethod(cls, loadSel, (IMP)swizzled_loadAd, "v@:");
                    }
                }
            }
            
            os_log(OS_LOG_DEFAULT, "[AppLovinFix] Ghost SDK Active. Instances will be valid but dormant.");
        }
    });
}
