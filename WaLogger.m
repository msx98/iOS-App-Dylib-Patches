#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// --- Logger Macro and Helper ---
#define log_debug(fmt, ...) \
    do { \
        NSString *msg = [NSString stringWithFormat:@"[WaLogger] " fmt, ##__VA_ARGS__]; \
        NSLog(@"%@", msg); \
        write_to_log_file(msg); \
    } while (0);

static void write_to_log_file(NSString *message) {
    static NSDateFormatter *dateFormatter = nil;
    static NSFileHandle *fileHandle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *logPath = [docPath stringByAppendingPathComponent:@"call_intercept_log.txt"];
        
        NSFileManager *dfm = [NSFileManager defaultManager];
        if (![dfm fileExistsAtPath:logPath]) {
            [dfm createFileAtPath:logPath contents:nil attributes:nil];
        }
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    });

    if (fileHandle) {
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
        
        // Prepare data
        NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        NSData *data = [logLine dataUsingEncoding:NSUTF8StringEncoding];
        
        if (data) {
            [fileHandle writeData:data];
            [fileHandle synchronizeFile]; // Flush to disk
        }
    }
}

// --- Swizzling Helper ---

static void swizzle_wa(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    
    if (!originalMethod || !swizzledMethod) {
        log_debug(@"Error: Missing method for selector %@", NSStringFromSelector(originalSelector));
        return;
    }

    method_exchangeImplementations(originalMethod, swizzledMethod);
}

// --- Hook Implementation ---

@interface NSObject (WACallHooks)
@end

@implementation NSObject (WACallHooks)

- (void)hook_setLgcParticipantJIDs:(id)arg1 {
    log_debug(@"setLgcParticipantJIDs: %@", arg1);
    [self hook_setLgcParticipantJIDs:arg1];
}

- (void)hook_setOfferProcessed:(BOOL)arg1 {
    log_debug(@"setOfferProcessed: %@", arg1 ? @"YES" : @"NO");
    [self hook_setOfferProcessed:arg1];
}

- (void)hook_setCallOfferID:(id)arg1 {
    log_debug(@"setCallOfferID: %@", arg1);
    [self hook_setCallOfferID:arg1];
}

- (void)hook_setIsCallOfferRering:(BOOL)arg1 {
    log_debug(@"setIsCallOfferRering: %@", arg1 ? @"YES" : @"NO");
    [self hook_setIsCallOfferRering:arg1];
}

- (void)hook_setOldCallWaitingType:(NSInteger)arg1 {
    log_debug(@"setOldCallWaitingType: %ld", (long)arg1);
    [self hook_setOldCallWaitingType:arg1];
}

- (void)hook_setEndedTimestamp:(id)arg1 {
    log_debug(@"setEndedTimestamp: %@", arg1);
    [self hook_setEndedTimestamp:arg1];
}

- (void)hook_setCallID:(id)arg1 {
    log_debug(@"setCallID: %@", arg1);
    [self hook_setCallID:arg1];
}

@end

static Class find_wa_class() {
    Class cls;
    NSArray *candidates = @[
        @"WhatsApp.WACall", 
        @"WACall", 
        @"_TtC8WhatsApp6WACall", // Common mangled name
        @"Core.WACall"           // Sometimes moved to a Core module
    ];

    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (cls) {
            log_debug(@"[WaLogger] Success! Found class with name: %@", name);
            return cls;
        }
    }
    return nil;
}

// --- Constructor ---
__attribute__((constructor))
static void init_logger_hooks() {
    log_debug(@"called init_logger_hooks()")
    Class waCallClass = find_wa_class();
    
    if (waCallClass) {
        swizzle_wa(waCallClass, @selector(setLgcParticipantJIDs:), @selector(hook_setLgcParticipantJIDs:));
        swizzle_wa(waCallClass, @selector(setOfferProcessed:), @selector(hook_setOfferProcessed:));
        swizzle_wa(waCallClass, @selector(setCallOfferID:), @selector(hook_setCallOfferID:));
        swizzle_wa(waCallClass, @selector(setIsCallOfferRering:), @selector(hook_setIsCallOfferRering:));
        swizzle_wa(waCallClass, @selector(setOldCallWaitingType:), @selector(hook_setOldCallWaitingType:));
        swizzle_wa(waCallClass, @selector(setEndedTimestamp:), @selector(hook_setEndedTimestamp:));
        swizzle_wa(waCallClass, @selector(setCallID:), @selector(hook_setCallID:));
        
        log_debug(@"Hooks applied to WhatsApp.WACall successfully.");
    } else {
        log_debug(@"[WaLogger] Critical: WhatsApp.WACall class not found.");
    }
}
