#import <Foundation/Foundation.h>
#include <objc/objc.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CloudKit/CloudKit.h>
#import <objc/runtime.h>
#import <math.h>

#import "utils.h"

#define BREAKPOINT if (true) { \
    debug_print(@"Breakpoint hit at line %d! Pause and run 'j +1' in lldb to continue execution.", __LINE__+1); \
    sleep(3600); \
}

static Class getClass(const char *name) {
    debug_print(@"Looking for class %s", name);
    Class cls = objc_getClass(name);
    if (!cls) {
        debug_print(@"Failed to find class %s", name);
    } else {
        debug_print(@"Found class %s", name);
    }
    return cls;
}

static IMP replaceClassSelector(Class c, SEL orig, IMP newImp) {
    const char *className = class_getName(c);
    const char *selName = sel_getName(orig);
    NSString *key = [NSString stringWithFormat:@"%s.%s", className, selName];
    debug_print(@"Attempting to swizzle %s.%s", className, selName);
    Method m = class_getInstanceMethod(c, orig);
    IMP originalImp = NULL;
    if (m) {
        originalImp = method_getImplementation(m);
        if (!originalImp) {
            debug_print(@"Failed to get original implementation for %s.%s", className, selName);
        }
        debug_print(@"Swizzling %s.%s", className, selName);
        method_setImplementation(m, newImp);
        debug_print(@"Swizzled %s.%s", className, selName);
    } else {
        debug_print(@"Failed to find method %s for swizzling in class %s.", sel_getName(orig), class_getName(c));
    }
    return originalImp;
}

typedef void (^CKAccountStatusBlock)(CKAccountStatus accountStatus, NSError *error);
static IMP orig_defaultContainer = NULL;
static IMP orig_objectForKey = NULL;

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"T_SLTokens"]) {
        debug_print(@"Blocking T_SLTokens from NSUbiquitousKeyValueStore (would cause otherSession auth)");
        return nil;
    }
    return ((id (*)(id, SEL, NSString *))orig_objectForKey)(self, _cmd, key);
}

void hooked_accountStatus(id self, SEL _cmd, CKAccountStatusBlock completionHandler) {
    if (completionHandler) completionHandler(CKAccountStatusAvailable, nil);
}


@interface PhantomDatabase : NSProxy
@end

@implementation PhantomDatabase

// Handle Swift's .fetch(withRecordID:completionHandler:)
// In Obj-C this is usually: fetchRecordWithID:completionHandler:
- (void)fetchRecordWithID:(CKRecordID *)recordID completionHandler:(void (^)(CKRecord *record, NSError *error))completionHandler {
    debug_print(@"fetchRecordWithID: called with recordID: %@", recordID.recordName);
    if (completionHandler) {
        debug_print(@"Creating fake record for ID: %@", recordID.recordName);
        // Create the record shell. CKRecord is a data object and usually safe to init.
        CKRecord *fakeRecord = [[CKRecord alloc] initWithRecordType:@"FakeType" recordID:recordID];
        
        // Match your Swift code's expectation: 
        // it wants a String, then converts it to Data(base64Encoded:)
        uint8_t buffer[256] = {0};
        memcpy(buffer, "FakeData", 8);
        NSData *rawBytes = [NSData dataWithBytes:buffer length:256];
        NSString *base64String = [rawBytes base64EncodedStringWithOptions:0];
        
        [fakeRecord setObject:base64String forKey:@"data"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            debug_print(@"Returning fake record for fetchRecordWithID: %@", recordID.recordName);
            completionHandler(fakeRecord, nil);
        });
    }
}

// Boilerplate to satisfy the runtime
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSClassFromString(@"CKDatabase") instanceMethodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    // We don't have a real database, so we just return nil for anything we didn't hook.
    id nilValue = nil;
    [invocation setReturnValue:&nilValue];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [NSClassFromString(@"CKDatabase") instancesRespondToSelector:aSelector];
}
@end

// --- Global Swizzling Logic ---
@interface PhantomContainer : NSProxy
@end

@implementation PhantomContainer


static PhantomDatabase *getGlobalPhantomDb() {
    debug_print(@"getGlobalPhantomDb() called, returning singleton PhantomDatabase instance");
    static PhantomDatabase *db = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        debug_print(@"Initializing global PhantomDatabase instance");
        db = [PhantomDatabase alloc];
    });
    return db;
}

// Intercept the database request
- (id)databaseWithDatabaseScope:(NSInteger)scope {
    return getGlobalPhantomDb();
}

- (id)publicCloudDatabase {
    return getGlobalPhantomDb();
}

// Intercept account status check
- (void)accountStatusWithCompletionHandler:(void (^)(CKAccountStatus accountStatus, NSError *error))completionHandler {
    if (completionHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(CKAccountStatusAvailable, nil);
        });
    }
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSClassFromString(@"CKContainer") instanceMethodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id nilValue = nil;
    [invocation setReturnValue:&nilValue];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [NSClassFromString(@"CKContainer") instancesRespondToSelector:aSelector];
}
@end

static PhantomContainer *proxy = nil;
static id hooked_defaultContainer(id self, SEL _cmd) {
    // 1. Call original implementation to get the real singleton container
    debug_print(@"hooked_defaultContainer() called for id %@, selector %s", self, sel_getName(_cmd));
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxy = [PhantomContainer alloc]; // NSProxy uses alloc, not init
    });
    debug_print(@"Returning PhantomContainer proxy for defaultContainer");
    return proxy;
}

void install_cloudkit_bypass() {
    Class ckContainer = objc_getClass("CKContainer");
    if (!ckContainer) return;

    replaceClassSelector(
        ckContainer,
        @selector(accountStatusWithCompletionHandler:), 
        imp_implementationWithBlock(^(id self, CKAccountStatusBlock completionHandler) {
            debug_print(@"accountStatusWithCompletionHandler: called, returning available status");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    debug_print(@"Invoking completion handler with CKAccountStatusAvailable");
                    completionHandler(CKAccountStatusAvailable, nil);
                });
            }
        })
    );
    Class ckMeta = object_getClass(ckContainer);

    // We only need to hook the entry point: +[CKContainer defaultContainer]
    Method m = class_getClassMethod(ckContainer, @selector(defaultContainer));
    orig_defaultContainer = method_setImplementation(m, (IMP)hooked_defaultContainer);

    if (orig_defaultContainer) {
        debug_print(@"Successfully hooked CKContainer.defaultContainer");
    } else {
        debug_print(@"Failed to hook CKContainer.defaultContainer");
    }

    m = class_getClassMethod(ckContainer, @selector(containerWithIdentifier:));
    method_setImplementation(m, imp_implementationWithBlock(^(id self, NSString *identifier) {
        debug_print(@"containerWithIdentifier: called with identifier: %@", identifier);
        return proxy;
    }));

    // Block T_SLTokens from NSUbiquitousKeyValueStore so auth.sendCode doesn't
    // include existing session tokens, which would cause the server to return
    // otherSession instead of sms for new account registration.
    /*
    Class kvStore = objc_getClass("NSUbiquitousKeyValueStore");
    if (kvStore) {
        Method kvMethod = class_getInstanceMethod(kvStore, @selector(objectForKey:));
        if (kvMethod) {
            orig_objectForKey = method_setImplementation(kvMethod, (IMP)hooked_objectForKey);
            debug_print(@"Successfully hooked NSUbiquitousKeyValueStore.objectForKey:");
        } else {
            debug_print(@"Failed to find NSUbiquitousKeyValueStore.objectForKey:");
        }
    } else {
        debug_print(@"Failed to find NSUbiquitousKeyValueStore class");
    }
    */
    
    debug_print(@"Total Proxy Bypass Active.");
}

// signal handler to prevent crashes when CloudKit calls the original methods that we have hooked to return nil
void signal_handler(int signal) {
    debug_print(@"Received signal %d, likely due to CloudKit calling original method. Ignoring to prevent crash.", signal);
}

static void register_signal_handler() {
    signal(SIGSEGV, signal_handler);
    signal(SIGABRT, signal_handler);
    signal(SIGFPE, signal_handler);
    signal(SIGILL, signal_handler);
    signal(SIGBUS, signal_handler);
}

void init() {
    register_signal_handler();
    install_cloudkit_bypass();
}


