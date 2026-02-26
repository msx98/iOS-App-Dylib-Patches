#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

static IMP origSetSecureTextField = NULL;
static IMP origSetSecureTextView = NULL;
static IMP origGetSecureTextField = NULL;
static IMP origGetSecureTextView = NULL;
static IMP origWAGetSecure = NULL;
static IMP origWASetSecure = NULL;

static void hookClass(Class cls, IMP *origLoad, IMP *origStore) {
  debug_print(@"[BypassSecureEntry] Hooking %s", class_getName(cls));
  if (!cls)
    return;

  // Getter: isSecureTextEntry → always NO
  Method getterMethod =
      class_getInstanceMethod(cls, @selector(isSecureTextEntry));
  if (getterMethod) {
    *origLoad = method_getImplementation(getterMethod);
    IMP *captured = origLoad;
    BOOL (^getterBlock)(id) = ^BOOL(id self) {
      BOOL val =
          ((BOOL(*)(id, SEL))(*captured))(self, @selector(isSecureTextEntry));
      NSArray<NSString *> *stack = [NSThread callStackSymbols];
      debug_print(
          @"[BypassSecureEntry] isSecureTextEntry called on %@ → %d:\n%@", self,
          val, [stack componentsJoinedByString:@"\n"]);
      return val;
    };
    class_replaceMethod(cls, @selector(isSecureTextEntry),
                        imp_implementationWithBlock(getterBlock), "B@:");
  }

  // Setter: setSecureTextEntry: → always NO (text stays visible)
  Method setterMethod =
      class_getInstanceMethod(cls, @selector(setSecureTextEntry:));
  if (setterMethod) {
    debug_print(@"[BypassSecureEntry] Hooking %s setSecureTextEntry:",
                class_getName(cls));
    *origStore = method_getImplementation(setterMethod);
    IMP *captured = origStore;
    void (^setterBlock)(id, BOOL) = ^(id self, BOOL _ignored) {
      ((void (*)(id, SEL, BOOL))*captured)(self, @selector(setSecureTextEntry:),
                                           NO);
    };
    method_setImplementation(setterMethod,
                             imp_implementationWithBlock(setterBlock));
  }

  debug_print(@"[BypassSecureEntry] Hooked %s", class_getName(cls));
}

static void hookBlockScreenshotView() {
  Class cls = objc_getClass("WABlockScreenshotDescriptionView");
  if (!cls) {
    debug_print(
        @"[BypassSecureEntry] WABlockScreenshotDescriptionView not found");
    return;
  }

  void (^setAlpha)(id, CGFloat) = ^(id self, CGFloat _ignored) {
  };
  void (^setOpacity)(id, float) = ^(id self, float _ignored) {
  };
  IMP uiviewSetHidden = class_getMethodImplementation(objc_getClass("UIView"),
                                                      @selector(setHidden:));
  void (^setHidden)(id, BOOL) = ^(id self, BOOL _ignored) {
    ((void (*)(id, SEL, BOOL))uiviewSetHidden)(self, @selector(setHidden:),
                                               YES);
  };

  class_replaceMethod(cls, @selector(setAlpha:),
                      imp_implementationWithBlock(setAlpha), "v@:d");
  class_replaceMethod(cls, @selector(setOpacity:),
                      imp_implementationWithBlock(setOpacity), "v@:f");
  class_replaceMethod(cls, @selector(setHidden:),
                      imp_implementationWithBlock(setHidden), "v@:B");

  // Also hook alpha/opacity/hidden getters to return the hardcoded values
  class_replaceMethod(cls, @selector(alpha),
                      imp_implementationWithBlock(^CGFloat(id self) {
                        return 0.0;
                      }),
                      "d@:");
  class_replaceMethod(cls, @selector(isHidden),
                      imp_implementationWithBlock(^BOOL(id self) {
                        return YES;
                      }),
                      "B@:");

  // When inserted into the hierarchy, hide self + direct parent + direct
  // children
  void (^didMove)(id) = ^(id self) {
    ((void (*)(id, SEL, BOOL))uiviewSetHidden)(self, @selector(setHidden:),
                                               YES);
    id superview = ((id(*)(id, SEL))objc_msgSend)(self, @selector(superview));
    if (superview)
      ((void (*)(id, SEL, BOOL))uiviewSetHidden)(superview,
                                                 @selector(setHidden:), YES);
    NSArray *subviews =
        ((id(*)(id, SEL))objc_msgSend)(self, @selector(subviews));
    for (id child in subviews)
      ((void (*)(id, SEL, BOOL))uiviewSetHidden)(child, @selector(setHidden:),
                                                 YES);
    debug_print(@"[BypassSecureEntry] didMoveToSuperview: hid self + parent + "
                @"%lu children",
                (unsigned long)subviews.count);
  };
  class_replaceMethod(cls, @selector(didMoveToSuperview),
                      imp_implementationWithBlock(didMove), "v@:");

  // Passthrough getter: log caller without changing the return value
  origWAGetSecure =
      class_getMethodImplementation(cls, @selector(isSecureTextEntry));
  BOOL (^getSecure)(id) = ^BOOL(id self) {
    BOOL val =
        ((BOOL(*)(id, SEL))origWAGetSecure)(self, @selector(isSecureTextEntry));
    NSArray *stack = [NSThread callStackSymbols];
    debug_print(@"[BypassSecureEntry] WABlockScreenshotDescriptionView "
                @"isSecureTextEntry → %d\n%@",
                val, [stack componentsJoinedByString:@"\n"]);
    return val;
  };
  class_replaceMethod(cls, @selector(isSecureTextEntry),
                      imp_implementationWithBlock(getSecure), "B@:");

  // Passthrough setter: log caller without changing the value passed through
  origWASetSecure =
      class_getMethodImplementation(cls, @selector(setSecureTextEntry:));
  void (^setSecure)(id, BOOL) = ^(id self, BOOL val) {
    NSArray *stack = [NSThread callStackSymbols];
    debug_print(@"[BypassSecureEntry] WABlockScreenshotDescriptionView "
                @"setSecureTextEntry:%d\n%@",
                val, [stack componentsJoinedByString:@"\n"]);
    ((void (*)(id, SEL, BOOL))origWASetSecure)(
        self, @selector(setSecureTextEntry:), val);
  };
  class_replaceMethod(cls, @selector(setSecureTextEntry:),
                      imp_implementationWithBlock(setSecure), "v@:B");

  debug_print(@"[BypassSecureEntry] WABlockScreenshotDescriptionView hooked");
}

static void init() {
  hookClass(objc_getClass("UITextField"), &origGetSecureTextField,
            &origSetSecureTextField);
  hookClass(objc_getClass("UITextView"), &origGetSecureTextView,
            &origSetSecureTextView);
  hookBlockScreenshotView();
  debug_print(@"[BypassSecureEntry] Hooks installed");
}

INITIALIZE("BypassSecureEntry")
