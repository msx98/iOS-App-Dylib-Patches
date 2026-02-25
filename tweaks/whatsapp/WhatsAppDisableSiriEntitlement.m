#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#include "../../lib/utils/utils.m"

// Define our dummy class
@interface MyDummyVocabulary : NSObject
@end

@implementation MyDummyVocabulary

// Specialized handler for the common vocabulary sync call
- (void)setVocabulary:(NSSet *)vocabulary ofType:(NSInteger)type {
    os_log(OS_LOG_DEFAULT, "=== IT WORKED! Intercepted setVocabulary ofType: %ld ===", (long)type);
}

// Catch-all: prevent crashes for any other Siri-related methods
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    os_log(OS_LOG_DEFAULT, "=== SWALLOWED UNKNOWN CALL: %{public}s ===", sel_getName([anInvocation selector]));
}

- (instancetype)init {
    if ((self = [super init])) {
        os_log(OS_LOG_DEFAULT, "=== MyDummyVocabulary Initialized ===");
    }
    return self;
}
@end




static void init() {
    Class originalClass = objc_getClass("INVocabulary");
    if (originalClass) {
        id (^swizzleBlock)(id) = ^id(id self) {
            static MyDummyVocabulary *dummy = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                dummy = [[MyDummyVocabulary alloc] init];
            });
            return dummy;
        };

        SEL selector = sel_registerName("sharedVocabulary");
        IMP newImp = imp_implementationWithBlock(swizzleBlock);
        class_replaceMethod(object_getClass(originalClass), selector, newImp, "@@:");
        os_log(OS_LOG_DEFAULT, "=== INVocabulary Swizzled Successfully ===");
    }

}

INITIALIZE("WhatsAppDisableSiriEntitlement")
