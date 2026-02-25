#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * SafeJumpBlocker.m
 * Block-based swizzling to prevent stack alignment crashes on arm64.
 */

__attribute__((constructor))
static void init_SafeJumpBlocker() {
    // 1. Hook openURL:options:completionHandler:
    Class appCls = [UIApplication class];
    SEL openSel = @selector(openURL:options:completionHandler:);
    Method mOpen = class_getInstanceMethod(appCls, openSel);
    
    if (mOpen) {
        __block IMP origOpen = method_getImplementation(mOpen);
        id block = ^BOOL(UIApplication *self, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
            NSString *urlString = url.absoluteString.lowercaseString;
            if ([urlString containsString:@"itunes.apple.com"] || [urlString containsString:@"apps.apple.com"] || [urlString hasPrefix:@"http"]) {
                os_log(OS_LOG_DEFAULT, "[SafeJump] Blocked external jump: %{public}s", [url.absoluteString UTF8String]);
                if (completion) completion(NO);
                return NO;
            }
            // Call original safely
            return ((BOOL (*)(id, SEL, id, id, id))origOpen)(self, openSel, url, options, completion);
        };
        method_setImplementation(mOpen, imp_implementationWithBlock(block));
    }

    // 2. Hook presentViewController:animated:completion:
    Class vcCls = [UIViewController class];
    SEL presentSel = @selector(presentViewController:animated:completion:);
    Method mPresent = class_getInstanceMethod(vcCls, presentSel);

    if (mPresent) {
        __block IMP origPresent = method_getImplementation(mPresent);
        id block = ^(UIViewController *self, UIViewController *vc, BOOL animated, void (^completion)(void)) {
            NSString *className = NSStringFromClass([vc class]);
            
            // Blacklist check
            if ([className containsString:@"Safari"] || [className containsString:@"StoreProduct"]) {
                os_log(OS_LOG_DEFAULT, "[SafeJump] Blocked mini-window: %{public}s", [className UTF8String]);
                if (completion) completion();
                return;
            }
            
            // Call original using proper casting for arm64
            ((void (*)(id, SEL, id, BOOL, id))origPresent)(self, presentSel, vc, animated, completion);
        };
        method_setImplementation(mPresent, imp_implementationWithBlock(block));
    }
    
    os_log(OS_LOG_DEFAULT, "[SafeJump] Protections initialized via safe blocks.");
}
