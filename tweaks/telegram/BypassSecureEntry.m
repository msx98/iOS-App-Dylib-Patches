#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

static IMP origSetSecureTextField = NULL;
static IMP origSetSecureTextView = NULL;

static void hookClass(Class cls, IMP *origStore) {
  if (!cls)
    return;

  // Getter: isSecureTextEntry → always YES
  BOOL (^getterBlock)(id) = ^BOOL(id self) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    debug_print(@"[BypassSecureEntry] isSecureTextEntry called on %@:\n%@",
                self, [stack componentsJoinedByString:@"\n"]);
    return NO;
  };
  class_replaceMethod(cls, @selector(isSecureTextEntry),
                      imp_implementationWithBlock(getterBlock), "B@:");

  // Setter: setSecureTextEntry: → always NO (text stays visible)
  Method setterMethod =
      class_getInstanceMethod(cls, @selector(setSecureTextEntry:));
  if (setterMethod) {
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

static void init() {
  hookClass(objc_getClass("UITextField"), &origSetSecureTextField);
  hookClass(objc_getClass("UITextView"), &origSetSecureTextView);
  debug_print(@"[BypassSecureEntry] Hooks installed");
}

INITIALIZE("BypassSecureEntry")
