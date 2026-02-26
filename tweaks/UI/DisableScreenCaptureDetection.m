#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../../lib/utils/utils.m"

// Storage for captured screenshot notification observers
static NSMutableArray<NSMutableDictionary *> *sSelectorObservers;
static NSMutableArray<NSMutableDictionary *> *sBlockObservers;

// ─── Part 1: UIScreen hooks
// ───────────────────────────────────────────────────

@implementation UIScreen (ScreenCaptureBypass)

- (BOOL)bypass_isCaptured {
  debug_print(@"[UIScreen] isCaptured — returning NO");
  return NO;
}

@end

// ─── Part 2: Manual dispatch
// ──────────────────────────────────────────────────

void dispatchScreenshotNotification(void) {
  NSNotification *note = [NSNotification
      notificationWithName:UIApplicationUserDidTakeScreenshotNotification
                    object:[UIApplication sharedApplication]];

  for (NSDictionary *entry in [sSelectorObservers copy]) {
    id observer = entry[@"observer"];
    SEL sel = NSSelectorFromString(entry[@"selector"]);
    if ([observer respondsToSelector:sel])
      [observer performSelector:sel withObject:note];
  }

  for (NSDictionary *entry in [sBlockObservers copy]) {
    void (^block)(NSNotification *) = entry[@"block"];
    NSOperationQueue *queue = entry[@"queue"];
    if ([queue isKindOfClass:[NSOperationQueue class]])
      [queue addOperationWithBlock:^{
        block(note);
      }];
    else
      block(note);
  }

  debug_print(@"[ScreenshotInterception] Dispatched to %lu selector + %lu "
              @"block observers",
              (unsigned long)sSelectorObservers.count,
              (unsigned long)sBlockObservers.count);
}

// ─── Init
// ─────────────────────────────────────────────────────────────────────

static void hook(Class cls, SEL sel, IMP newImp) {
  Method m = class_getInstanceMethod(cls, sel);
  if (m)
    method_setImplementation(m, newImp);
  else
    debug_print(
        @"[DisableScreenCaptureDetection] WARNING: method not found: %@",
        NSStringFromSelector(sel));
}

static BOOL isValueChangeDisabled = NO;

static void init() {
  Class us = object_getClass([UIScreen mainScreen]);
  Class nc = object_getClass([NSNotificationCenter defaultCenter]);

  debug_print(@"[DisableScreenCaptureDetection] UIScreen class: %@",
              NSStringFromClass(us));
  debug_print(@"[DisableScreenCaptureDetection] NC class: %@",
              NSStringFromClass(nc));

  // ── UIScreen.isCaptured → always NO ────────────────────────────────────────
  // Defeats the initial subscriber.putNext(UIScreen.main.isCaptured) check
  // in screenRecordingActive() so it never emits .video on startup.
  {
    Method m =
        class_getInstanceMethod([UIScreen class], @selector(bypass_isCaptured));
    hook(us, @selector(isCaptured), method_getImplementation(m));
  }

  // ── UIScreen KVO: intercept at registration level for "captured"
  // ──────────── UIKit uses a private notification path that bypasses
  // didChangeValueForKey:, so suppressing that method has no effect. Instead,
  // use class_addMethod to add UIScreen-specific overrides that drop "captured"
  // registrations entirely. Observers that never register never fire,
  // regardless of UIKit internals. We also no-op the removeObserver variants so
  // Telegram's clear() doesn't throw an NSException about an unregistered
  // observer.
  {
    Method addM = class_getInstanceMethod(
        [NSObject class], @selector(addObserver:forKeyPath:options:context:));
    IMP addOrig = method_getImplementation(addM);
    class_addMethod(
        us, @selector(addObserver:forKeyPath:options:context:),
        imp_implementationWithBlock(^(
            UIScreen *self_, id observer, NSString *keyPath,
            NSKeyValueObservingOptions opts, void *ctx) {
          if ([keyPath isEqualToString:@"captured"]) {
            debug_print(@"[UIScreen] Dropped KVO registration for 'captured'");
            return;
          }
          ((void (*)(id, SEL, id, NSString *, NSKeyValueObservingOptions,
                     void *))addOrig)(self_,
                                      @selector(addObserver:
                                                 forKeyPath:options:context:),
                                      observer, keyPath, opts, ctx);
        }),
        method_getTypeEncoding(addM));

    Method rmM = class_getInstanceMethod([NSObject class],
                                         @selector(removeObserver:forKeyPath:));
    IMP rmOrig = method_getImplementation(rmM);
    class_addMethod(
        us, @selector(removeObserver:forKeyPath:),
        imp_implementationWithBlock(^(UIScreen *self_, id observer,
                                      NSString *keyPath) {
          if ([keyPath isEqualToString:@"captured"]) {
            debug_print(@"[UIScreen] No-op KVO removal for 'captured'");
            return;
          }
          ((void (*)(id, SEL, id, NSString *))rmOrig)(
              self_, @selector(removeObserver:forKeyPath:), observer, keyPath);
        }),
        method_getTypeEncoding(rmM));

    Method rmCtxM = class_getInstanceMethod(
        [NSObject class], @selector(removeObserver:forKeyPath:context:));
    IMP rmCtxOrig = method_getImplementation(rmCtxM);
    class_addMethod(
        us, @selector(removeObserver:forKeyPath:context:),
        imp_implementationWithBlock(^(UIScreen *self_, id observer,
                                      NSString *keyPath, void *ctx) {
          if ([keyPath isEqualToString:@"captured"]) {
            debug_print(@"[UIScreen] No-op KVO removal (ctx) for 'captured'");
            return;
          }
          ((void (*)(id, SEL, id, NSString *, void *))rmCtxOrig)(
              self_, @selector(removeObserver:forKeyPath:context:), observer,
              keyPath, ctx);
        }),
        method_getTypeEncoding(rmCtxM));
  }

  // ── NSNotificationCenter hooks
  // ────────────────────────────────────────────── Each hook captures the
  // original IMP before replacing it so the non- screenshot path calls straight
  // back into the real implementation.

  sSelectorObservers = [NSMutableArray new];
  sBlockObservers = [NSMutableArray new];

  // addObserver:selector:name:object:
  {
    IMP orig = method_getImplementation(class_getInstanceMethod(
        nc, @selector(addObserver:selector:name:object:)));
    hook(nc, @selector(addObserver:selector:name:object:),
         imp_implementationWithBlock(^(id self_, id observer, SEL sel,
                                       NSNotificationName name, id obj) {
           if ([name isEqualToString:
                         UIApplicationUserDidTakeScreenshotNotification]) {
             [sSelectorObservers addObject:[@{
                                   @"observer" : observer,
                                   @"selector" : NSStringFromSelector(sel),
                                   @"object" : obj ?: [NSNull null]
                                 } mutableCopy]];
             debug_print(@"[ScreenshotInterception] Captured selector-based "
                         @"observer: %@",
                         NSStringFromClass([observer class]));
             return;
           }
           ((void (*)(id, SEL, id, SEL, NSNotificationName, id))orig)(
               self_, @selector(addObserver:selector:name:object:), observer,
               sel, name, obj);
         }));
  }

  // addObserverForName:object:queue:usingBlock:
  {
    IMP orig = method_getImplementation(class_getInstanceMethod(
        nc, @selector(addObserverForName:object:queue:usingBlock:)));
    hook(nc, @selector(addObserverForName:object:queue:usingBlock:),
         imp_implementationWithBlock(^id(id self_, NSNotificationName name,
                                         id obj, NSOperationQueue *queue,
                                         void (^block)(NSNotification *)) {
           if ([name isEqualToString:
                         UIApplicationUserDidTakeScreenshotNotification]) {
             id token = [NSObject new];
             [sBlockObservers addObject:[@{
                                @"token" : token,
                                @"block" : [block copy],
                                @"queue" : queue ?: [NSNull null],
                                @"object" : obj ?: [NSNull null]
                              } mutableCopy]];
             debug_print(@"[ScreenshotInterception] Captured block-based "
                         @"observer (token %p)",
                         token);
             return token;
           }
           return ((id(*)(id, SEL, NSNotificationName, id, NSOperationQueue *,
                          void (^)(NSNotification *)))orig)(
               self_, @selector(addObserverForName:object:queue:usingBlock:),
               name, obj, queue, block);
         }));
  }

  // removeObserver:name:object:
  {
    IMP orig = method_getImplementation(
        class_getInstanceMethod(nc, @selector(removeObserver:name:object:)));
    hook(nc, @selector(removeObserver:name:object:),
         imp_implementationWithBlock(
             ^(id self_, id observer, NSNotificationName name, id obj) {
               if ([name isEqualToString:
                             UIApplicationUserDidTakeScreenshotNotification]) {
                 [sSelectorObservers
                     filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                           NSDictionary *e,
                                                           NSDictionary *_) {
                       return e[@"observer"] != observer;
                     }]];
                 [sBlockObservers
                     filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                           NSDictionary *e,
                                                           NSDictionary *_) {
                       return e[@"token"] != observer;
                     }]];
                 return;
               }
               ((void (*)(id, SEL, id, NSNotificationName, id))orig)(
                   self_, @selector(removeObserver:name:object:), observer,
                   name, obj);
             }));
  }

  // removeObserver:
  {
    IMP orig = method_getImplementation(
        class_getInstanceMethod(nc, @selector(removeObserver:)));
    hook(nc, @selector(removeObserver:),
         imp_implementationWithBlock(^(id self_, id observer) {
           [sSelectorObservers
               filterUsingPredicate:[NSPredicate
                                        predicateWithBlock:^BOOL(
                                            NSDictionary *e, NSDictionary *_) {
                                          return e[@"observer"] != observer;
                                        }]];
           [sBlockObservers
               filterUsingPredicate:[NSPredicate
                                        predicateWithBlock:^BOOL(
                                            NSDictionary *e, NSDictionary *_) {
                                          return e[@"token"] != observer;
                                        }]];
           ((void (*)(id, SEL, id))orig)(self_, @selector(removeObserver:),
                                         observer);
         }));
  }

  // postNotification: — the fundamental dispatch path all named variants hit
  {
    IMP orig = method_getImplementation(
        class_getInstanceMethod(nc, @selector(postNotification:)));
    hook(nc, @selector(postNotification:),
         imp_implementationWithBlock(^(id self_, NSNotification *note) {
           if ([note.name isEqualToString:
                              UIApplicationUserDidTakeScreenshotNotification]) {
             debug_print(@"[ScreenshotInterception] Swallowed screenshot "
                         @"(postNotification:)");
             return;
           }
           ((void (*)(id, SEL, NSNotification *))orig)(
               self_, @selector(postNotification:), note);
         }));
  }

  // postNotificationName:object:
  {
    IMP orig = method_getImplementation(
        class_getInstanceMethod(nc, @selector(postNotificationName:object:)));
    hook(nc, @selector(postNotificationName:object:),
         imp_implementationWithBlock(
             ^(id self_, NSNotificationName name, id obj) {
               if ([name isEqualToString:
                             UIApplicationUserDidTakeScreenshotNotification]) {
                 debug_print(@"[ScreenshotInterception] Swallowed screenshot "
                             @"(postNotificationName:object:)");
                 return;
               }
               ((void (*)(id, SEL, NSNotificationName, id))orig)(
                   self_, @selector(postNotificationName:object:), name, obj);
             }));
  }

  // postNotificationName:object:userInfo:
  {
    IMP orig = method_getImplementation(class_getInstanceMethod(
        nc, @selector(postNotificationName:object:userInfo:)));
    hook(nc, @selector(postNotificationName:object:userInfo:),
         imp_implementationWithBlock(^(id self_, NSNotificationName name,
                                       id obj, NSDictionary *userInfo) {
           if ([name isEqualToString:
                         UIApplicationUserDidTakeScreenshotNotification]) {
             debug_print(@"[ScreenshotInterception] Swallowed screenshot "
                         @"(postNotificationName:object:userInfo:)");
             return;
           }
           ((void (*)(id, SEL, NSNotificationName, id, NSDictionary *))orig)(
               self_, @selector(postNotificationName:object:userInfo:), name,
               obj, userInfo);
         }));
  }

  debug_print(@"[DisableScreenCaptureDetection] All hooks installed");
}

INITIALIZE("DisableScreenCaptureDetection")
