#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

#define TAG @"[RemoveObserver]"

// Weak set of observers that called addObserver:forKeyPath:captured on UIScreen.
// We block the add and track them here for periodic logging.
static NSHashTable *gObservers;

static void (*gOrigAdd)(id, SEL, id, NSString *, NSKeyValueObservingOptions,
                        void *) = NULL;
static void (*gOrigRemove)(id, SEL, id, NSString *) = NULL;
static BOOL (*gOrigIsCaptured)(id, SEL) = NULL;

static void (*gOrigPostNotification)(id, SEL, id) = NULL;
static void (*gOrigPostNotificationNameObject)(id, SEL, NSString *, id) = NULL;
static void (*gOrigPostNotificationNameObjectUserInfo)(id, SEL, NSString *, id,
                                                       NSDictionary *) = NULL;

// ── UIScreen addObserver:forKeyPath:options:context: hook ─────────────────────
// For keyPath "captured": block the registration entirely and track the caller.
// For all other keyPaths: pass through to NSObject's implementation.
static void hooked_addObserver(id self, SEL _cmd, id observer,
                               NSString *keyPath,
                               NSKeyValueObservingOptions options,
                               void *context) {
  if ([keyPath isEqualToString:@"captured"]) {
    debug_print(TAG @" BLOCKED addObserver:forKeyPath:captured observer=%p",
                observer);
    @synchronized(gObservers) {
      [gObservers addObject:observer];
    }
    return; // Do NOT call through — observer is never registered.
  }
  gOrigAdd(self, _cmd, observer, keyPath, options, context);
}

// ── UIScreen removeObserver:forKeyPath: hook ──────────────────────────────────
// For keyPath "captured": no-op (the observer was never added, so calling
// through would throw NSInternalInconsistencyException).
// For all other keyPaths: pass through.
static void hooked_removeObserver(id self, SEL _cmd, id observer,
                                  NSString *keyPath) {
  if ([keyPath isEqualToString:@"captured"]) {
    debug_print(TAG @" BLOCKED removeObserver:forKeyPath:captured observer=%p",
                observer);
    return;
  }
  gOrigRemove(self, _cmd, observer, keyPath);
}

// ── UIScreen.isCaptured spoof ─────────────────────────────────────────────────
// Always returns NO so the initial isCaptured read in screenRecordingActive()
// never triggers content hiding.
static BOOL hooked_isCaptured(id self, SEL _cmd) {
  debug_print(TAG @" isCaptured spoofed → NO");
  return NO;
}

// ── NSNotificationCenter capturedDidChangeNotification filter ─────────────────
// The system posts UIScreenCapturedDidChangeNotification when the real capture
// state changes. This wakes Telegram up to call isCaptured regardless of KVO.
// Swallow it at the posting level so no observer ever sees it.
#define CAPTURED_NOTIF @"UIScreenCapturedDidChangeNotification"

static BOOL isCaptureNotification(NSString *name) {
  return [name isEqualToString:CAPTURED_NOTIF];
}

static void hooked_postNotification(id self, SEL _cmd, NSNotification *note) {
  if (isCaptureNotification(note.name)) {
    debug_print(TAG @" SWALLOWED NSNotification: %@", note.name);
    return;
  }
  gOrigPostNotification(self, _cmd, note);
}

static void hooked_postNotificationNameObject(id self, SEL _cmd, NSString *name,
                                              id obj) {
  if (isCaptureNotification(name)) {
    debug_print(TAG @" SWALLOWED postNotificationName: %@", name);
    return;
  }
  gOrigPostNotificationNameObject(self, _cmd, name, obj);
}

static void hooked_postNotificationNameObjectUserInfo(id self, SEL _cmd,
                                                      NSString *name, id obj,
                                                      NSDictionary *info) {
  if (isCaptureNotification(name)) {
    debug_print(TAG @" SWALLOWED postNotificationName:object:userInfo: %@", name);
    return;
  }
  gOrigPostNotificationNameObjectUserInfo(self, _cmd, name, obj, info);
}

static void installHooks(void) {
  Class uiScreen = NSClassFromString(@"UIScreen");

  // isCaptured property getter
  {
    SEL sel = sel_registerName("isCaptured");
    Method m = class_getInstanceMethod(uiScreen, sel);
    if (m) {
      gOrigIsCaptured = (typeof(gOrigIsCaptured))method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_isCaptured);
      debug_print(TAG @" Hooked UIScreen isCaptured");
    } else {
      debug_print(TAG @" WARNING: UIScreen isCaptured not found");
    }
  }

  // addObserver:forKeyPath:options:context:
  {
    SEL sel = @selector(addObserver:forKeyPath:options:context:);
    Method m = class_getInstanceMethod([NSObject class], sel);
    gOrigAdd = (typeof(gOrigAdd))method_getImplementation(m);
    class_replaceMethod(uiScreen, sel, (IMP)hooked_addObserver,
                        method_getTypeEncoding(m));
    debug_print(TAG @" Hooked UIScreen addObserver:forKeyPath:options:context:");
  }

  // removeObserver:forKeyPath:
  {
    SEL sel = @selector(removeObserver:forKeyPath:);
    Method m = class_getInstanceMethod([NSObject class], sel);
    gOrigRemove = (typeof(gOrigRemove))method_getImplementation(m);
    class_replaceMethod(uiScreen, sel, (IMP)hooked_removeObserver,
                        method_getTypeEncoding(m));
    debug_print(TAG @" Hooked UIScreen removeObserver:forKeyPath:");
  }

  // NSNotificationCenter — swallow UIScreenCapturedDidChangeNotification
  {
    Class nc = [NSNotificationCenter class];

    Method m1 = class_getInstanceMethod(nc, @selector(postNotification:));
    gOrigPostNotification =
        (typeof(gOrigPostNotification))method_getImplementation(m1);
    method_setImplementation(m1, (IMP)hooked_postNotification);

    Method m2 =
        class_getInstanceMethod(nc, @selector(postNotificationName:object:));
    gOrigPostNotificationNameObject =
        (typeof(gOrigPostNotificationNameObject))method_getImplementation(m2);
    method_setImplementation(m2, (IMP)hooked_postNotificationNameObject);

    Method m3 = class_getInstanceMethod(
        nc, @selector(postNotificationName:object:userInfo:));
    gOrigPostNotificationNameObjectUserInfo =
        (typeof(gOrigPostNotificationNameObjectUserInfo))method_getImplementation(
            m3);
    method_setImplementation(m3,
                             (IMP)hooked_postNotificationNameObjectUserInfo);

    debug_print(TAG @" Hooked NSNotificationCenter post* (filtering %@)",
                CAPTURED_NOTIF);
  }
}

static void init() {
  debug_print(TAG @" Initializing...");
  gObservers = [NSHashTable weakObjectsHashTable];

  installHooks();

  // Periodic sweep: log any live blocked observers.
  dispatch_source_t timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
  dispatch_source_set_timer(timer,
                            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                            2 * NSEC_PER_SEC, (uint64_t)(0.5 * NSEC_PER_SEC));
  dispatch_source_set_event_handler(timer, ^{
    NSArray *snapshot;
    @synchronized(gObservers) {
      snapshot = gObservers.allObjects;
    }
    if (snapshot.count > 0) {
      debug_print(TAG @" %lu blocked ScreenRecordingObserver instance(s) still live:",
                  (unsigned long)snapshot.count);
      for (id obs in snapshot) {
        debug_print(TAG @"   %p (%@)", obs,
                    NSStringFromClass(object_getClass(obs)));
      }
    }
  });
  dispatch_resume(timer);

  debug_print(TAG @" Initialized");
}

INITIALIZE("RemoveObserver")
