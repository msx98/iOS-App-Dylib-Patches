#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * bidmachineHide.m
 * Immediate override of BidMachineSdk initialization and state.
 */

// 1. Mock for - (void)initializeSdk:(NSString *)sourceId
static void mock_bidmachine_init(id self, SEL _cmd, NSString *sourceId) {
    os_log(OS_LOG_DEFAULT, "[BidMachineHide] Intercepted initializeSdk with ID: %{public}s", [sourceId UTF8String]);
    // BidMachine init is usually void and doesn't use a completion block in this signature,
    // but the SDK sets an internal flag we need to spoof via the getter below.
}

// 2. Mock for - (BOOL)isInitialized
static BOOL mock_isInitialized(id self, SEL _cmd) {
    return YES;
}

__attribute__((constructor))
static void init_BidMachineMock() {
    // Try namespaced and standard class names
    NSArray *possibleNames = @[@"BidMachine.BidMachineSdk", @"BidMachineSdk"];
    Class sdkCls = nil;

    for (NSString *name in possibleNames) {
        sdkCls = objc_getClass([name UTF8String]);
        if (sdkCls) {
            os_log(OS_LOG_DEFAULT, "[BidMachineHide] Found class: %{public}s", [name UTF8String]);
            break;
        }
    }

    if (sdkCls) {
        // --- Hook Instance Method: initializeSdk: ---
        SEL initSel = sel_registerName("initializeSdk:");
        Method mInit = class_getInstanceMethod(sdkCls, initSel);
        if (mInit) {
            class_replaceMethod(sdkCls, initSel, (IMP)mock_bidmachine_init, "v@:@");
        }

        // --- Hook Instance Method: isInitialized ---
        SEL stateSel = sel_registerName("isInitialized");
        Method mState = class_getInstanceMethod(sdkCls, stateSel);
        if (mState) {
            class_replaceMethod(sdkCls, stateSel, (IMP)mock_isInitialized, "B@:");
        }
        
        os_log(OS_LOG_DEFAULT, "[BidMachineHide] BidMachine is now fully mocked.");
    } else {
        os_log(OS_LOG_DEFAULT, "[BidMachineHide] Error: BidMachineSdk class not found.");
    }
}
