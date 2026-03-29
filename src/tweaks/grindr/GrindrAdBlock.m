#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>

// ============================================================
// AppLovin (TelegramFix-style background session / notification silence)
// ============================================================

static id (*orig_backgroundConfig)(id, SEL, NSString *);
static id swizzled_backgroundConfig(id self, SEL _cmd, NSString *identifier) {
    os_log(OS_LOG_DEFAULT, "[AppLovin] Downgrading Background Session: %{public}s", [identifier UTF8String]);
    return [NSURLSessionConfiguration defaultSessionConfiguration];
}

static void swizzled_getDelivered(id self, SEL _cmd, void(^completionHandler)(NSArray<UNNotification *> *)) {
    if (completionHandler) completionHandler(@[]);
}

static void swizzled_getPending(id self, SEL _cmd, void(^completionHandler)(NSArray<UNNotificationRequest *> *)) {
    if (completionHandler) completionHandler(@[]);
}

__attribute__((constructor))
static void init_AppLovinFix() {
    Method mBg = class_getClassMethod([NSURLSessionConfiguration class], @selector(backgroundSessionConfigurationWithIdentifier:));
    if (mBg) {
        orig_backgroundConfig = (void *)method_getImplementation(mBg);
        method_setImplementation(mBg, (IMP)swizzled_backgroundConfig);
    }

    Class unCenterCls = [UNUserNotificationCenter class];

    Method mDelivered = class_getInstanceMethod(unCenterCls, @selector(getDeliveredNotificationsWithCompletionHandler:));
    if (mDelivered) method_setImplementation(mDelivered, (IMP)swizzled_getDelivered);

    Method mPending = class_getInstanceMethod(unCenterCls, @selector(getPendingNotificationRequestsWithCompletionHandler:));
    if (mPending) method_setImplementation(mPending, (IMP)swizzled_getPending);

    Method mBadge = class_getInstanceMethod([UIApplication class], @selector(setApplicationIconBadgeNumber:));
    if (mBadge) method_setImplementation(mBadge, imp_implementationWithBlock(^(id _self, NSInteger badge){ }));

    os_log(OS_LOG_DEFAULT, "[AppLovin] Background and notification traps silenced.");
}

// ============================================================
// AppLovin MAX (ALSdk / MARewardedAd / MAInterstitialAd / MAAdView)
// ============================================================

static void swizzled_alSdkInit(id self, SEL _cmd, id config, void (^block)(id)) {
    os_log(OS_LOG_DEFAULT, "[AppLovinMax] Neutralized ALSdk init. Firing fake success.");
    if (block) block(nil);
}

static void swizzled_loadAd(id self, SEL _cmd) {
    os_log(OS_LOG_DEFAULT, "[AppLovinMax] Blocked loadAd for %{public}s",
           [NSStringFromClass([self class]) UTF8String]);
}

__attribute__((constructor))
static void init_AppLovinMax() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class sdkCls = objc_getClass("ALSdk");
        if (sdkCls) {
            SEL initSel = sel_registerName("initializeWithConfiguration:completionHandler:");
            Method mInit = class_getClassMethod(sdkCls, initSel);
            if (mInit) {
                class_replaceMethod(object_getClass(sdkCls), initSel, (IMP)swizzled_alSdkInit, "v@:@@?");
            }

            for (NSString *name in @[@"MARewardedAd", @"MAInterstitialAd", @"MAAdView"]) {
                Class cls = objc_getClass([name UTF8String]);
                if (cls) {
                    SEL loadSel = sel_registerName("loadAd");
                    Method mLoad = class_getInstanceMethod(cls, loadSel);
                    if (mLoad) class_replaceMethod(cls, loadSel, (IMP)swizzled_loadAd, "v@:");
                }
            }

            os_log(OS_LOG_DEFAULT, "[AppLovinMax] Ghost SDK active.");
        }
    });
}

// ============================================================
// BidMachine
// ============================================================

static void mock_bidmachine_init(id self, SEL _cmd, NSString *sourceId) {
    os_log(OS_LOG_DEFAULT, "[BidMachine] Intercepted initializeSdk: %{public}s", [sourceId UTF8String]);
}

static BOOL mock_bidmachine_isInitialized(id self, SEL _cmd) {
    return YES;
}

__attribute__((constructor))
static void init_BidMachine() {
    Class sdkCls = nil;
    for (NSString *name in @[@"BidMachine.BidMachineSdk", @"BidMachineSdk"]) {
        sdkCls = objc_getClass([name UTF8String]);
        if (sdkCls) {
            os_log(OS_LOG_DEFAULT, "[BidMachine] Found class: %{public}s", [name UTF8String]);
            break;
        }
    }

    if (sdkCls) {
        SEL initSel = sel_registerName("initializeSdk:");
        Method mInit = class_getInstanceMethod(sdkCls, initSel);
        if (mInit) class_replaceMethod(sdkCls, initSel, (IMP)mock_bidmachine_init, "v@:@");

        SEL stateSel = sel_registerName("isInitialized");
        Method mState = class_getInstanceMethod(sdkCls, stateSel);
        if (mState) class_replaceMethod(sdkCls, stateSel, (IMP)mock_bidmachine_isInitialized, "B@:");

        os_log(OS_LOG_DEFAULT, "[BidMachine] Fully mocked.");
    }
}

// ============================================================
// GrindrAds (UIView collapse for GrindrAdsImpl / GrindrCascade)
// ============================================================

static void (*orig_didMoveToWindow)(id, SEL);

static void FullyCollapse(UIView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alpha = 0.0;
    CGRect frame = view.frame;
    frame.size.height = 0;
    view.frame = frame;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight) constraint.active = NO;
    }
}

static void swizzled_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_didMoveToWindow(self, _cmd);
    NSString *className = NSStringFromClass([self class]);

    if ([className hasPrefix:@"GrindrAdsImpl."]) {
        os_log(OS_LOG_DEFAULT, "[GrindrAds] Banner: %{public}s", [className UTF8String]);
        FullyCollapse(self);
        UIView *parent = self.superview;
        if (parent && ![parent isKindOfClass:[UIWindow class]]) FullyCollapse(parent);
    } else if ([className hasPrefix:@"GrindrCascade.ServerDrivenCascadeAdCell"]) {
        os_log(OS_LOG_DEFAULT, "[GrindrAds] Cascade: %{public}s", [className UTF8String]);
        FullyCollapse(self);
    }
}

__attribute__((constructor))
static void init_GrindrAds() {
    Method m = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
    if (m) {
        orig_didMoveToWindow = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_didMoveToWindow);
        os_log(OS_LOG_DEFAULT, "[GrindrAds] View blocker initialized.");
    }
}

// ============================================================
// SafariPopupBlocker (openURL + presentViewController)
// ============================================================

__attribute__((constructor))
static void init_SafariPopupBlocker() {
    Class appCls = [UIApplication class];
    SEL openSel = @selector(openURL:options:completionHandler:);
    Method mOpen = class_getInstanceMethod(appCls, openSel);
    if (mOpen) {
        __block IMP origOpen = method_getImplementation(mOpen);
        id block = ^BOOL(UIApplication *self, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
            NSString *urlString = url.absoluteString.lowercaseString;
            if ([urlString containsString:@"itunes.apple.com"] ||
                [urlString containsString:@"apps.apple.com"] ||
                [urlString hasPrefix:@"http"]) {
                os_log(OS_LOG_DEFAULT, "[SafariPopup] Blocked external jump: %{public}s", [url.absoluteString UTF8String]);
                if (completion) completion(NO);
                return NO;
            }
            return ((BOOL (*)(id, SEL, id, id, id))origOpen)(self, openSel, url, options, completion);
        };
        method_setImplementation(mOpen, imp_implementationWithBlock(block));
    }

    Class vcCls = [UIViewController class];
    SEL presentSel = @selector(presentViewController:animated:completion:);
    Method mPresent = class_getInstanceMethod(vcCls, presentSel);
    if (mPresent) {
        __block IMP origPresent = method_getImplementation(mPresent);
        id block = ^(UIViewController *self, UIViewController *vc, BOOL animated, void (^completion)(void)) {
            NSString *className = NSStringFromClass([vc class]);
            if ([className containsString:@"Safari"] || [className containsString:@"StoreProduct"]) {
                os_log(OS_LOG_DEFAULT, "[SafariPopup] Blocked mini-window: %{public}s", [className UTF8String]);
                if (completion) completion();
                return;
            }
            ((void (*)(id, SEL, id, BOOL, id))origPresent)(self, presentSel, vc, animated, completion);
        };
        method_setImplementation(mPresent, imp_implementationWithBlock(block));
    }

    os_log(OS_LOG_DEFAULT, "[SafariPopup] Initialized.");
}

// ============================================================
// Unity Ads
// ============================================================

static void mock_unity_load(id self, SEL _cmd, NSString *adUnitId, id delegate) {
    os_log(OS_LOG_DEFAULT, "[Unity] Blocked load for unit: %{public}s", [adUnitId UTF8String]);
}

static void mock_unity_init(id self, SEL _cmd, NSString *gameId, BOOL testMode, id delegate) {
    os_log(OS_LOG_DEFAULT, "[Unity] Intercepted initialize with GameID: %{public}s", [gameId UTF8String]);
    if (delegate) {
        SEL successSel = sel_registerName("initializationComplete");
        if ([delegate respondsToSelector:successSel]) {
            void (*sendSuccess)(id, SEL) = (void *)objc_msgSend;
            sendSuccess(delegate, successSel);
        }
    }
}

__attribute__((constructor))
static void init_Unity() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class unityCls = nil;
        for (NSString *name in @[@"UnityAds.UnityAds", @"UnityAds"]) {
            unityCls = objc_getClass([name UTF8String]);
            if (unityCls) {
                os_log(OS_LOG_DEFAULT, "[Unity] Found class: %{public}s", [name UTF8String]);
                break;
            }
        }

        if (unityCls) {
            Class metaCls = object_getClass(unityCls);

            SEL initSel = sel_registerName("initialize:testMode:initializationDelegate:");
            Method mInit = class_getClassMethod(unityCls, initSel);
            if (mInit) class_replaceMethod(metaCls, initSel, (IMP)mock_unity_init, "v@:@B@");

            SEL loadSel = sel_registerName("load:loadDelegate:");
            Method mLoad = class_getClassMethod(unityCls, loadSel);
            if (mLoad) class_replaceMethod(metaCls, loadSel, (IMP)mock_unity_load, "v@:@@");

            os_log(OS_LOG_DEFAULT, "[Unity] Fully mocked.");
        }
    });
}

// ============================================================
// Vungle Ads
// ============================================================

static void mock_vungle_init(id self, SEL _cmd, NSString *appId, void (^completion)(NSError *)) {
    os_log(OS_LOG_DEFAULT, "[Vungle] Intercepted init. Firing completion(nil).");
    if (completion) completion(nil);
}

static BOOL mock_vungle_isInitialized(id self, SEL _cmd) {
    return NO;
}

__attribute__((constructor))
static void init_Vungle() {
    int attempts = 0;
    Class vungleCls = objc_getClass("VungleAdsSDK.VungleAds");
    while (!vungleCls && attempts < 100) {
        vungleCls = objc_getClass("VungleAds");
        if (!vungleCls) { attempts++; usleep(10000); }
    }

    if (vungleCls) {
        Class metaCls = object_getClass(vungleCls);

        SEL initSel = sel_registerName("initWithAppId:completion:");
        Method mInit = class_getClassMethod(vungleCls, initSel);
        if (mInit) class_replaceMethod(metaCls, initSel, (IMP)mock_vungle_init, "v@:@@?");

        SEL stateSel = sel_registerName("isInitialized");
        Method mState = class_getClassMethod(vungleCls, stateSel);
        if (mState) class_replaceMethod(metaCls, stateSel, (IMP)mock_vungle_isInitialized, "B@:");

        os_log(OS_LOG_DEFAULT, "[Vungle] Fully mocked.");
    }
}
