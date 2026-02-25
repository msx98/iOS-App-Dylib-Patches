#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>

/**
 * telegramFix.m - Version 2 (The "Quiet" Edition)
 */

// --- 1. Fix URLSession (Downgrade Background to Default) ---
static id (*orig_backgroundConfig)(id, SEL, NSString *);
static id swizzled_backgroundConfig(id self, SEL _cmd, NSString *identifier) {
    os_log(OS_LOG_DEFAULT, "[TelegramFix] Downgrading Background Session: %{public}s", [identifier UTF8String]);
    return [NSURLSessionConfiguration defaultSessionConfiguration];
}

// --- 2. Silence UNUserNotificationCenter (Stop Entitlement Faults) ---
// We override these to return empty results before the system can deny us.
static void swizzled_getDelivered(id self, SEL _cmd, void(^completionHandler)(NSArray<UNNotification *> *)) {
    os_log(OS_LOG_DEFAULT, "[TelegramFix] Swallowed getDeliveredNotifications check.");
    if (completionHandler) completionHandler(@[]);
}

static void swizzled_getPending(id self, SEL _cmd, void(^completionHandler)(NSArray<UNNotificationRequest *> *)) {
    os_log(OS_LOG_DEFAULT, "[TelegramFix] Swallowed getPendingNotificationRequests check.");
    if (completionHandler) completionHandler(@[]);
}

__attribute__((constructor))
static void init_TelegramFix_V2() {
    // 1. URLSession Fix
    Method mBg = class_getClassMethod([NSURLSessionConfiguration class], @selector(backgroundSessionConfigurationWithIdentifier:));
    if (mBg) {
        orig_backgroundConfig = (void *)method_getImplementation(mBg);
        method_setImplementation(mBg, (IMP)swizzled_backgroundConfig);
    }

    // 2. Notification Center Fixes
    Class unCenterCls = [UNUserNotificationCenter class];
    
    SEL deliveredSel = @selector(getDeliveredNotificationsWithCompletionHandler:);
    Method mDelivered = class_getInstanceMethod(unCenterCls, deliveredSel);
    if (mDelivered) method_setImplementation(mDelivered, (IMP)swizzled_getDelivered);

    SEL pendingSel = @selector(getPendingNotificationRequestsWithCompletionHandler:);
    Method mPending = class_getInstanceMethod(unCenterCls, pendingSel);
    if (mPending) method_setImplementation(mPending, (IMP)swizzled_getPending);

    // 3. Silence Icon Badge
    Method mBadge = class_getInstanceMethod([UIApplication class], @selector(setApplicationIconBadgeNumber:));
    if (mBadge) method_setImplementation(mBadge, imp_implementationWithBlock(^(id _self, NSInteger badge){ }));

    os_log(OS_LOG_DEFAULT, "[TelegramFix] V2: All background and notification traps silenced.");
}
