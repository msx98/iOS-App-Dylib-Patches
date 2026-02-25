#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

/**
 * AdBlock - Selective Parent Blocker
 * Logic: 
 * - GrindrAdsImpl.* -> Collapse self AND parent.
 * - GrindrCascade.* -> Collapse self ONLY.
 */

static void (*orig_didMoveToWindow)(id, SEL);

static void FullyCollapse(UIView *view) {
    if (!view) return;
    
    view.hidden = YES;
    view.alpha = 0.0;
    
    // Force frame to zero
    CGRect frame = view.frame;
    frame.size.height = 0;
    view.frame = frame;
    
    // Override Auto Layout
    view.translatesAutoresizingMaskIntoConstraints = YES;
    
    // Deactivate height constraints
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight) {
            constraint.active = NO;
        }
    }
}

static void swizzled_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_didMoveToWindow(self, _cmd);
    
    NSString *className = NSStringFromClass([self class]);
    
    // 1. Handle Banners/Interstitials (Collapse self + parent)
    if ([className hasPrefix:@"GrindrAdsImpl."]) {
        os_log(OS_LOG_DEFAULT, "[AdBlock] Banner target: %{public}s", [className UTF8String]);
        FullyCollapse(self);
        
        UIView *parent = self.superview;
        if (parent && ![parent isKindOfClass:[UIWindow class]]) {
            FullyCollapse(parent);
        }
    } 
    // 2. Handle Grid/Cascade Cells (Collapse self only)
    else if ([className hasPrefix:@"GrindrCascade.ServerDrivenCascadeAdCell"]) {
        os_log(OS_LOG_DEFAULT, "[AdBlock] Cascade target: %{public}s", [className UTF8String]);
        FullyCollapse(self);
        // We explicitly do NOT touch the superview here to keep the grid intact.
    }
}

__attribute__((constructor))
static void init_SelectiveBlocker() {
    Method m = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
    if (m) {
        orig_didMoveToWindow = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_didMoveToWindow);
        os_log(OS_LOG_DEFAULT, "[AdBlock] Selective Namespace blocker initialized.");
    }
}
