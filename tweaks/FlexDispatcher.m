#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * FlexDispatcher
 * Uses EXPORT visibility to ensure the Mach-O header marks this as a valid entry point.
 */

__attribute__((visibility("default"))) 
__attribute__((constructor))
static void forceLaunchFLEX() {
        os_log(OS_LOG_DEFAULT, "[FlexDispatcher] Starting initialization sequence BEFORE...");
    // 5-second delay to ensure the app's UIWindow is actually the KeyWindow.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        os_log(OS_LOG_DEFAULT, "[FlexDispatcher] Starting initialization sequence...");

        // 1. Dynamic class lookup
        Class flexManager = objc_getClass("FLEXManager");
        
        if (!flexManager) {
            os_log_error(OS_LOG_DEFAULT, "[FlexDispatcher] FATAL: FLEXManager not found. Execution halted.");
            // Manual crash to verify the dylib code was reached
            __builtin_trap(); 
        }

        // 2. Safe selector execution
        SEL sharedSel = sel_registerName("sharedManager");
        SEL showSel = sel_registerName("showExplorer");

        if ([flexManager respondsToSelector:sharedSel]) {
            id sharedManager = [flexManager performSelector:sharedSel];
            
            if ([sharedManager respondsToSelector:showSel]) {
                [sharedManager performSelector:showSel];
                os_log(OS_LOG_DEFAULT, "[FlexDispatcher] FLEX UI should now be visible.");
            } else {
                 os_log_error(OS_LOG_DEFAULT, "[FlexDispatcher] sharedManager failed to respond to showExplorer.");
                 __builtin_trap();
            }
        } else {
            os_log_error(OS_LOG_DEFAULT, "[FlexDispatcher] FLEXManager failed to respond to sharedManager.");
            __builtin_trap();
        }
    });
}
