#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>


static IMP origSetSecureTextField = NULL;
static IMP origSetSecureTextView = NULL;

static void hookClass(Class cls, IMP *origStore) {
  if (!cls)
    return;

  // Getter: isSecureTextEntry → always NO
  class_replaceMethod(cls, @selector(isSecureTextEntry),
                      imp_implementationWithBlock(^BOOL(id _self) { return NO; }),
                      "B@:");

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

}

void init() {
  hookClass(objc_getClass("UITextField"), &origSetSecureTextField);
  hookClass(objc_getClass("UITextView"), &origSetSecureTextView);
}


