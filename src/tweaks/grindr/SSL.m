#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

#import "utils.h"
#import "submodules/fishhook/fishhook.h"

// ─── SecTrust hooks (fishhook) ────────────────────────────────────────────────
//
// Covers CFNetwork / NSURLSession built-in certificate validation.
// GrindrNetworking calls SecTrustEvaluateWithError before its own hash check,
// so this must also pass to avoid any early-exit failure paths.

static bool (*orig_SecTrustEvaluateWithError)(SecTrustRef, CFErrorRef *);
static OSStatus (*orig_SecTrustEvaluate)(SecTrustRef, SecTrustResultType *);
static OSStatus (*orig_SecTrustGetTrustResult)(SecTrustRef, SecTrustResultType *);

static bool hooked_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
  debug_print(@"[Grindr/SSL] SecTrustEvaluateWithError — bypassed");
  if (error) *error = NULL;
  return true;
}

static OSStatus hooked_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
  debug_print(@"[Grindr/SSL] SecTrustEvaluate — bypassed");
  if (result) *result = kSecTrustResultProceed;
  return errSecSuccess;
}

static OSStatus hooked_SecTrustGetTrustResult(SecTrustRef trust, SecTrustResultType *result) {
  debug_print(@"[Grindr/SSL] SecTrustGetTrustResult — bypassed");
  if (result) *result = kSecTrustResultProceed;
  return errSecSuccess;
}

// ─── ATS bypass ───────────────────────────────────────────────────────────────

static NSDictionary *(*orig_infoDictionary)(NSBundle *, SEL);

static NSDictionary *hooked_infoDictionary(NSBundle *self_, SEL _cmd) {
  NSDictionary *orig = orig_infoDictionary(self_, _cmd);
  if (self_ != [NSBundle mainBundle])
    return orig;
  NSMutableDictionary *patched = orig ? [orig mutableCopy] : [NSMutableDictionary new];
  patched[@"NSAppTransportSecurity"] = @{@"NSAllowsArbitraryLoads": @YES};
  return patched;
}

// ─── PinningSessionDelegate bypass ───────────────────────────────────────────
//
// GrindrNetworking.PinningSessionDelegate implements
// URLSession:task:didReceiveChallenge:completionHandler: and performs
// public-key hash pinning against hardcoded SPKI hashes after trust
// evaluation. SecTrustEvaluateWithError returning true is not enough —
// the delegate reads the real cert from the SecTrustRef and compares its
// key hash independently. Hook the delegate method directly and accept the
// server's credential unconditionally.

static void (*orig_didReceiveChallenge)(id, SEL, NSURLSession *, NSURLSessionTask *,
                                        NSURLAuthenticationChallenge *,
                                        void (^)(NSURLSessionAuthChallengeDisposition,
                                                 NSURLCredential *));

static void hooked_didReceiveChallenge(id self_, SEL _cmd,
                                        NSURLSession *session,
                                        NSURLSessionTask *task,
                                        NSURLAuthenticationChallenge *challenge,
                                        void (^completionHandler)(NSURLSessionAuthChallengeDisposition,
                                                                   NSURLCredential *)) {
  if ([challenge.protectionSpace.authenticationMethod
          isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    debug_print(@"[Grindr/SSL] PinningSessionDelegate challenge — bypassed");
    NSURLCredential *cred =
        [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
    completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
    return;
  }
  orig_didReceiveChallenge(self_, _cmd, session, task, challenge, completionHandler);
}

// ─── UnsecureConnectionViewController stub ───────────────────────────────────
//
// Fallback layers in case the pinning hook is insufficient.
//   1. Swallow the notification before the VC is ever triggered.
//   2. Stub viewDidAppear: on the VC itself so it self-dismisses.

static void (*orig_postNotificationName)(id, SEL, NSNotificationName, id, NSDictionary *);

static void hooked_postNotificationName(id self_, SEL _cmd,
                                         NSNotificationName name,
                                         id object,
                                         NSDictionary *userInfo) {
  if ([name containsString:@"UnsecureConnection"]) {
    debug_print(@"[Grindr/SSL] Swallowed notification: %@", name);
    return;
  }
  orig_postNotificationName(self_, _cmd, name, object, userInfo);
}

static void hooked_viewDidAppear(UIViewController *self_, SEL _cmd, BOOL animated) {
  debug_print(@"[Grindr/SSL] UnsecureConnectionViewController appeared — dismissing");
  [self_ dismissViewControllerAnimated:NO completion:nil];
}

// ─── Init ─────────────────────────────────────────────────────────────────────

void init() {
  // SecTrust hooks via fishhook
  rebind_symbols(
      (struct rebinding[]){
          {"SecTrustEvaluateWithError", hooked_SecTrustEvaluateWithError,
           (void *)&orig_SecTrustEvaluateWithError},
          {"SecTrustEvaluate", hooked_SecTrustEvaluate,
           (void *)&orig_SecTrustEvaluate},
          {"SecTrustGetTrustResult", hooked_SecTrustGetTrustResult,
           (void *)&orig_SecTrustGetTrustResult},
      },
      3);

  // ATS bypass
  Method ib = class_getInstanceMethod([NSBundle class], @selector(infoDictionary));
  orig_infoDictionary = (NSDictionary *(*)(NSBundle *, SEL))method_getImplementation(ib);
  method_setImplementation(ib, (IMP)hooked_infoDictionary);

  // PinningSessionDelegate — bypass public-key hash comparison
  // ObjC class name confirmed from nm + swift-demangle on grindrx binary
  Class pinClass = NSClassFromString(@"GrindrNetworking.PinningSessionDelegate");
  if (pinClass) {
    SEL sel = @selector(URLSession:task:didReceiveChallenge:completionHandler:);
    Method pm = class_getInstanceMethod(pinClass, sel);
    if (pm) {
      orig_didReceiveChallenge =
          (void (*)(id, SEL, NSURLSession *, NSURLSessionTask *,
                    NSURLAuthenticationChallenge *,
                    void (^)(NSURLSessionAuthChallengeDisposition,
                             NSURLCredential *)))method_getImplementation(pm);
      method_setImplementation(pm, (IMP)hooked_didReceiveChallenge);
      debug_print(@"[Grindr/SSL] PinningSessionDelegate hook installed");
    } else {
      debug_print(@"[Grindr/SSL] WARNING: URLSession:task:didReceiveChallenge: not found on PinningSessionDelegate");
    }
  } else {
    debug_print(@"[Grindr/SSL] WARNING: PinningSessionDelegate class not found");
  }

  // Fallback Layer 1 — swallow UnsecureConnectionNotification
  Class nc = object_getClass([NSNotificationCenter defaultCenter]);
  Method m = class_getInstanceMethod(nc, @selector(postNotificationName:object:userInfo:));
  orig_postNotificationName = (void (*)(id, SEL, NSNotificationName, id, NSDictionary *))method_getImplementation(m);
  method_setImplementation(m, (IMP)hooked_postNotificationName);

  // Fallback Layer 2 — stub UnsecureConnectionViewController
  Class vcClass = NSClassFromString(@"_TtC7grindrx32UnsecureConnectionViewController");
  if (vcClass) {
    Method va = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
    if (va)
      true;//method_setImplementation(va, (IMP)hooked_viewDidAppear);
    else
      debug_print(@"[Grindr/SSL] WARNING: viewDidAppear: not found on UnsecureConnectionViewController");
  } else {
    debug_print(@"[Grindr/SSL] WARNING: UnsecureConnectionViewController class not found");
  }

  debug_print(@"[Grindr/SSL] All hooks installed");
}
