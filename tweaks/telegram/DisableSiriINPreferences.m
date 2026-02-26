#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

#include "../../lib/utils/utils.m"

// INSiriAuthorizationStatus enum values:
// 0 = NotDetermined, 1 = Restricted, 2 = Denied, 3 = Authorized
typedef NS_ENUM(NSInteger, INSiriAuthorizationStatus) {
  INSiriAuthorizationStatusDenied = 2,
};

static void init() {
  Class inPreferences = objc_getClass("INPreferences");
  if (!inPreferences) {
    debug_print(@"[DisableSiriINPreferences] INPreferences class not found");
    return;
  }

  // Spoof +siriAuthorizationStatus → Denied
  NSInteger (^statusBlock)(id) = ^NSInteger(id self) {
    debug_print(@"[DisableSiriINPreferences] siriAuthorizationStatus → Denied");
    return INSiriAuthorizationStatusDenied;
  };
  SEL statusSel = sel_registerName("siriAuthorizationStatus");
  IMP statusImp = imp_implementationWithBlock(statusBlock);
  class_replaceMethod(object_getClass(inPreferences), statusSel, statusImp,
                      "l@:");

  // Spoof +requestSiriAuthorization: → call back with Denied immediately
  void (^requestBlock)(id, void (^)(NSInteger)) =
      ^(id self, void (^handler)(NSInteger)) {
        debug_print(
            @"[DisableSiriINPreferences] requestSiriAuthorization: → Denied");
        if (handler)
          handler(INSiriAuthorizationStatusDenied);
      };
  SEL requestSel = sel_registerName("requestSiriAuthorization:");
  IMP requestImp = imp_implementationWithBlock(requestBlock);
  class_replaceMethod(object_getClass(inPreferences), requestSel, requestImp,
                      "v@:@");

  debug_print(@"[DisableSiriINPreferences] INPreferences hooks installed");
}

INITIALIZE("DisableSiriINPreferences")
