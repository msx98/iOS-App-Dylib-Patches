#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

/**
 * unityInitHide.m
 * Robust initialization override handling namespaced Unity classes.
 */

// --- 1. Mock for UnityAds load:loadDelegate: ---
static void mock_unity_load(id self, SEL _cmd, NSString *adUnitId, id delegate) {
    os_log(OS_LOG_DEFAULT, "[UnityHide] Intercepted load for unit: %{public}s. Silently ignoring.", [adUnitId UTF8String]);
}

// --- 2. Mock for UnityAds initialize:testMode:initializationDelegate: ---
static void mock_unity_init(id self, SEL _cmd, NSString *gameId, BOOL testMode, id delegate) {
    os_log(OS_LOG_DEFAULT, "[UnityHide] Intercepted initialize with GameID: %{public}s", [gameId UTF8String]);

    if (delegate) {
        SEL successSel = sel_registerName("initializationComplete");
        if ([delegate respondsToSelector:successSel]) {
            os_log(OS_LOG_DEFAULT, "[UnityHide] Spoofing initializationComplete on delegate.");

            void (*sendSuccess)(id, SEL) = (void *)objc_msgSend;
            sendSuccess(delegate, successSel);
        }
    }
}

__attribute__((constructor))
static void init_UnityGlobalMock() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        // Try common namespaced variations
        NSArray *possibleNames = @[@"UnityAds.UnityAds", @"UnityAds"];
        Class unityCls = nil;

        for (NSString *name in possibleNames) {
            unityCls = objc_getClass([name UTF8String]);
            if (unityCls) {
                os_log(OS_LOG_DEFAULT, "[UnityHide] Found Unity class as: %{public}s", [name UTF8String]);
                break;
            }
        }

        if (unityCls) {
            Class metaCls = object_getClass(unityCls);

            // Hook initialize:testMode:initializationDelegate:
            SEL initSel = sel_registerName("initialize:testMode:initializationDelegate:");
            Method mInit = class_getClassMethod(unityCls, initSel);
            if (mInit) {
                class_replaceMethod(metaCls, initSel, (IMP)mock_unity_init, "v@:@B@");
            }

            // Hook load:loadDelegate:
            SEL loadSel = sel_registerName("load:loadDelegate:");
            Method mLoad = class_getClassMethod(unityCls, loadSel);
            if (mLoad) {
                class_replaceMethod(metaCls, loadSel, (IMP)mock_unity_load, "v@:@@");
            }

            os_log(OS_LOG_DEFAULT, "[UnityHide] Unity initialization and loading fully mocked.");
        } else {
            os_log(OS_LOG_DEFAULT, "[UnityHide] Error: UnityAds class not found in any namespace.");
        }
    });
}
