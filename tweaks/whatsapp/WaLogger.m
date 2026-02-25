#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "utils/utils.m"
INITIALIZE("WaLogger");

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
  if ([className containsString:@"WACall"] ||
      [className containsString:@"CallManager"]) {
    debug_print(@"INSTANCE CREATED: %@", className);
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

void onLoad() { debug_print(@"WaLogger loaded."); }

void onInit() {
  // 1. Hook NSObject init to find the exact subclass name used during a call
  swizzle_any([NSObject class], @selector(init), @selector(discovery_init));

  // 2. Try to hook known candidates immediately
  NSArray *classes = @[
    @"WhatsApp.WACall", @"WACall", @"_TtC8WhatsApp6WACall",
    @"WhatsApp.WAGroupCall"
  ];
  for (NSString *name in classes) {
    Class cls = NSClassFromString(name);
    if (cls) {
      debug_print(@"Found candidate: %@. Hooking setters...", name);
      swizzle_any(cls, @selector(setCallID:), @selector(hook_generic_setter:));
      swizzle_any(cls, @selector(setLgcParticipantJIDs:),
                  @selector(hook_generic_setter:));
    }
  }
}
