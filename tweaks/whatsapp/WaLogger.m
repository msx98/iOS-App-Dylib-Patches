#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "../../lib/utils/utils.m"

static IMP hook_method(Class cls, SEL sel, IMP newIMP) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m)
    return NULL;
  IMP orig = method_getImplementation(m);
  if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m)))
    method_setImplementation(class_getInstanceMethod(cls, sel), newIMP);
  return orig;
}

static void hookWACallManager(void) {
  Class cls = NSClassFromString(@"WACallManager");
  if (!cls) {
    debug_print(@"[WaLogger] WACallManager not found");
    return;
  }

  // Outgoing 1:1 call
  {
    SEL sel = @selector
        (attemptOutgoingCallTo:
                   withChatJID:callUISource:withVideo:from:accountService
                              :chatStorage:createdWithoutContactBookAccess
                              :startCallTimestamp:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(
          ^(id self, id peerJIDs, id chatJID, NSInteger src, BOOL video,
            id from, id acct, id storage, BOOL noBook, id ts) {
            debug_print(@"[WACallManager] OUTGOING CALL → %@ (video=%d)",
                        chatJID, video);
            ((void (*)(id, SEL, id, id, NSInteger, BOOL, id, id, id, BOOL,
                       id))orig)(self, sel, peerJIDs, chatJID, src, video, from,
                                 acct, storage, noBook, ts);
          });
      hook_method(cls, sel, newIMP);
    }
  }

  // Incoming call
  {
    SEL sel = @selector(
        reportIncomingCallFromCallerJID:
                        participantJIDs:phoneUserCallerJID
                                       :phoneUserParticipantJIDs:usernameMapping
                                       :totalGroupParticipantCount:callID
                                       :groupJID:isVideo:isGroupCall
                                       :isCallLinkCall:isCAPICall
                                       :isParticipantCoexUser:forceToReport
                                       :isVoiceChat:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(
          ^(id self, id callerJID, id participantJIDs, id phoneCallerJID,
            id phoneParticipantJIDs, id usernameMapping, NSInteger totalCount,
            id callID, id groupJID, BOOL isVideo, BOOL isGroupCall,
            BOOL isCallLinkCall, BOOL isCAPICall, BOOL isCoexUser,
            BOOL forceReport, BOOL isVoiceChat) {
            debug_print(@"[WACallManager] INCOMING CALL from: %@ | callID: %@ "
                        @"| video: %d | group: %d",
                        callerJID, callID, isVideo, isGroupCall);
            ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id, id, BOOL,
                       BOOL, BOOL, BOOL, BOOL, BOOL, BOOL))orig)(
                self, sel, callerJID, participantJIDs, phoneCallerJID,
                phoneParticipantJIDs, usernameMapping, totalCount, callID,
                groupJID, isVideo, isGroupCall, isCallLinkCall, isCAPICall,
                isCoexUser, forceReport, isVoiceChat);
          });
      hook_method(cls, sel, newIMP);
    }
  }

  // Call connected
  {
    SEL sel = @selector(setCallConnected:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(id self, BOOL connected) {
        if (connected) {
          id peer = [self valueForKey:@"peerJid"];
          id callID = [self valueForKey:@"callID"];
          debug_print(@"[WACallManager] CALL CONNECTED | peer: %@ | callID: %@",
                      peer, callID);
        }
        ((void (*)(id, SEL, BOOL))orig)(self, sel, connected);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Call ending
  {
    SEL sel = @selector
        (voipBridgeCallIsEndingWithCallEvent:
                          showRatingInterval:callID:voipTimeSeriesSubDir
                                            :callResult:isGroupCall:isBotCall:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(
          ^(id self, id callEvent, double ratingInterval, NSString *callID,
            id subDir, NSInteger callResult, BOOL isGroupCall, BOOL isBotCall) {
            id peer = [self valueForKey:@"peerJid"];
            debug_print(@"[WACallManager] CALL ENDING | callID: %@ | peer: %@ "
                        @"| result: %ld | group: %d",
                        callID, peer, (long)callResult, isGroupCall);
            ((void (*)(id, SEL, id, double, NSString *, id, NSInteger, BOOL,
                       BOOL))orig)(self, sel, callEvent, ratingInterval, callID,
                                   subDir, callResult, isGroupCall, isBotCall);
          });
      hook_method(cls, sel, newIMP);
    }
  }
}

static void init() { hookWACallManager(); }

INITIALIZE("WaLogger")
