#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "../../lib/utils/utils.m"

static void write_to_log_file(NSString *message) {
  static NSFileHandle *fileHandle = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logPath =
        [docPath stringByAppendingPathComponent:@"call_intercept_log.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
      [[NSFileManager defaultManager] createFileAtPath:logPath
                                              contents:nil
                                            attributes:nil];
    }
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [fileHandle seekToEndOfFile];
  });
  if (fileHandle) {
    NSString *logLine =
        [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    [fileHandle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle synchronizeFile];
  }
}

// Global Swizzler
static void swizzle_any(Class cls, SEL originalSelector, SEL swizzledSelector) {
  Method originalMethod = class_getInstanceMethod(cls, originalSelector);
  Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
  if (originalMethod && swizzledMethod) {
    method_exchangeImplementations(originalMethod, swizzledMethod);
  }
}

@implementation NSObject (Discovery)

// Hooking init for ALL objects to find the WACall subclass
- (instancetype)discovery_init {
  NSString *className = NSStringFromClass([self class]);
  if ([className containsString:@"WACall"]) {
    debug_print(@"INSTANCE CREATED: %@; Properties: %@", className,
                [self valueForKey:@"debugDescription"]);
  }
  return [self discovery_init];
}

// Placeholder hooks for the dynamic discovery
- (void)hook_generic_setter:(id)arg1 {
  debug_print(@"[%@] SETTER CALLED with: %@", NSStringFromClass([self class]),
              arg1);
  [self hook_generic_setter:arg1];
}

@end

// Helper: add a method to cls if absent, otherwise replace the existing IMP.
// Returns the original IMP.
static IMP hook_method(Class cls, SEL sel, IMP newIMP) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return NULL;
  IMP orig = method_getImplementation(m);
  if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m)))
    method_setImplementation(class_getInstanceMethod(cls, sel), newIMP);
  return orig;
}

static void hookWACallManager(void) {
  Class cls = NSClassFromString(@"WACallManager");
  if (!cls) { debug_print(@"[WaLogger] WACallManager not found"); return; }

  // Outgoing 1:1 call
  {
    SEL sel = @selector(attemptOutgoingCallTo:withChatJID:callUISource:withVideo:from:accountService:chatStorage:createdWithoutContactBookAccess:startCallTimestamp:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(id self, id peerJIDs, id chatJID,
                                                  NSInteger src, BOOL video,
                                                  id from, id acct, id storage,
                                                  BOOL noBook, id ts) {
        debug_print(@"[WACallManager] OUTGOING CALL → %@ (video=%d)", chatJID, video);
        ((void(*)(id,SEL,id,id,NSInteger,BOOL,id,id,id,BOOL,id))orig)(self,sel,peerJIDs,chatJID,src,video,from,acct,storage,noBook,ts);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Incoming call
  {
    SEL sel = @selector(reportIncomingCallFromCallerJID:participantJIDs:phoneUserCallerJID:phoneUserParticipantJIDs:usernameMapping:totalGroupParticipantCount:callID:groupJID:isVideo:isGroupCall:isCallLinkCall:isCAPICall:isParticipantCoexUser:forceToReport:isVoiceChat:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(id self,
                                                  id callerJID, id participantJIDs,
                                                  id phoneCallerJID, id phoneParticipantJIDs,
                                                  id usernameMapping, NSInteger totalCount,
                                                  id callID, id groupJID,
                                                  BOOL isVideo, BOOL isGroupCall,
                                                  BOOL isCallLinkCall, BOOL isCAPICall,
                                                  BOOL isCoexUser, BOOL forceReport,
                                                  BOOL isVoiceChat) {
        debug_print(@"[WACallManager] INCOMING CALL from: %@ | callID: %@ | video: %d | group: %d",
                    callerJID, callID, isVideo, isGroupCall);
        ((void(*)(id,SEL,id,id,id,id,id,NSInteger,id,id,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL))orig)(
          self,sel,callerJID,participantJIDs,phoneCallerJID,phoneParticipantJIDs,
          usernameMapping,totalCount,callID,groupJID,
          isVideo,isGroupCall,isCallLinkCall,isCAPICall,isCoexUser,forceReport,isVoiceChat);
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
          debug_print(@"[WACallManager] CALL CONNECTED | peer: %@ | callID: %@", peer, callID);
        }
        ((void(*)(id,SEL,BOOL))orig)(self, sel, connected);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Call ending
  {
    SEL sel = @selector(voipBridgeCallIsEndingWithCallEvent:showRatingInterval:callID:voipTimeSeriesSubDir:callResult:isGroupCall:isBotCall:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(id self, id callEvent, double ratingInterval,
                                                  NSString *callID, id subDir,
                                                  NSInteger callResult, BOOL isGroupCall,
                                                  BOOL isBotCall) {
        id peer = [self valueForKey:@"peerJid"];
        debug_print(@"[WACallManager] CALL ENDING | callID: %@ | peer: %@ | result: %ld | group: %d",
                    callID, peer, (long)callResult, isGroupCall);
        ((void(*)(id,SEL,id,double,NSString*,id,NSInteger,BOOL,BOOL))orig)(
          self,sel,callEvent,ratingInterval,callID,subDir,callResult,isGroupCall,isBotCall);
      });
      hook_method(cls, sel, newIMP);
    }
  }
}

static void init() {
  // 1. Hook NSObject init to find the exact subclass name used during a call
  // swizzle_any([NSObject class], @selector(init), @selector(discovery_init));

  hookWACallManager();

  // 2. Try to hook known candidates immediately
  NSArray *classes = @[
    @"WACall",
    @"WACallEvent",
    @"WACallInfo",
    @"WACallManager",
  ];
  for (NSString *name in classes) {
    Class cls = NSClassFromString(name);
    if (cls) {
      // List all instance methods on this class
      unsigned int methodCount = 0;
      Method *methods = class_copyMethodList(cls, &methodCount);
      debug_print(@"[%@] %u instance methods:", name, methodCount);
      for (unsigned int i = 0; i < methodCount; i++) {
        debug_print(@"  - %s", sel_getName(method_getName(methods[i])));
      }
      free(methods);
      debug_print(@"Found candidate: %@. Hooking setters...", name);
      // replace init
      Method initMethod = class_getInstanceMethod(cls, @selector(init));
      if (initMethod) {
        // Replace init with a block that logs the class name and then calls the
        // original init
        IMP originalIMP = method_getImplementation(initMethod);
        debug_print(@"Hooking init for class: %@", name);
        const char *types = method_getTypeEncoding(initMethod);

        IMP newIMP = imp_implementationWithBlock(^id(id self) {
          NSString *className = NSStringFromClass([self class]);
          debug_print(@"[%@] init called", className);
          write_to_log_file(
              [NSString stringWithFormat:@"%@ init called", className]);
          return ((id(*)(id, SEL))originalIMP)(self, @selector(init));
        });
        // Add init to this specific class; if it already defines one, replace
        // it. Using class_addMethod avoids modifying the inherited superclass
        // method (which would hook NSObject and fire for every object in the
        // process).
        if (!class_addMethod(cls, @selector(init), newIMP, types)) {
          method_setImplementation(
              class_getInstanceMethod(cls, @selector(init)), newIMP);
        }
      } else {
        debug_print(@"WARNING: init method not found for class: %@", name);
      }
      debug_print(@"Initialization complete.");
    } else {
      debug_print(@"Candidate class not found: %@", name);
    }
  }
}

INITIALIZE("WaLogger")
