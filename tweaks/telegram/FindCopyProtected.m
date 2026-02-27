#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

static void hookClass(Class cls) {
	const char *name = class_getName(cls);

	Method cpGetter = class_getInstanceMethod(cls, @selector(isCopyProtected));
	if (cpGetter) {
		class_replaceMethod(cls, @selector(isCopyProtected),
			imp_implementationWithBlock(^BOOL(id self) { return NO; }), "B@:");
		debug_print(@"hooked isCopyProtected getter on %s", name);
	}

	Method cpSetter = class_getInstanceMethod(cls, @selector(setCopyProtected:));
	if (cpSetter) {
		class_replaceMethod(cls, @selector(setCopyProtected:),
			imp_implementationWithBlock(^void(id self, BOOL val) {}), "v@:B");
		debug_print(@"hooked setCopyProtected: setter on %s", name);
	}

	Method smGetter = class_getInstanceMethod(cls, @selector(containsSecretMedia));
	if (smGetter) {
		class_replaceMethod(cls, @selector(containsSecretMedia),
			imp_implementationWithBlock(^BOOL(id self) { return NO; }), "B@:");
		debug_print(@"hooked containsSecretMedia getter on %s", name);
	}

	Method smSetter = class_getInstanceMethod(cls, @selector(setContainsSecretMedia:));
	if (smSetter) {
		class_replaceMethod(cls, @selector(setContainsSecretMedia:),
			imp_implementationWithBlock(^void(id self, BOOL val) {}), "v@:B");
		debug_print(@"hooked setContainsSecretMedia: setter on %s", name);
	}

	Method cpeGetter = class_getInstanceMethod(cls, @selector(copyProtectionEnabled));
	if (cpeGetter) {
		class_replaceMethod(cls, @selector(copyProtectionEnabled),
			imp_implementationWithBlock(^BOOL(id self) { return NO; }), "B@:");
		debug_print(@"hooked copyProtectionEnabled getter on %s", name);
	}

	Method cpeSetter = class_getInstanceMethod(cls, @selector(setCopyProtectionEnabled:));
	if (cpeSetter) {
		class_replaceMethod(cls, @selector(setCopyProtectionEnabled:),
			imp_implementationWithBlock(^void(id self, BOOL val) {}), "v@:B");
		debug_print(@"hooked setCopyProtectionEnabled: setter on %s", name);
	}
}

static void listAllClasses() {
	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	if (!classes) {
		debug_print(@"objc_copyClassList returned nil");
		return;
	}

	debug_print(@"Loaded classes:");
	for (unsigned int i = 0; i < count; i++) {
		Class cls = classes[i];
		debug_print(@"- %s", class_getName(cls));
	}

	free(classes);
}

#include "Dobby/include/dobby.h"
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

typedef __attribute__((swiftcall)) void (*PerformTextSelectionActionFunc)(void* message, bool flag, void* attributedString, void* action);
static PerformTextSelectionActionFunc orig_performAction = NULL;

__attribute__((swiftcall))
void hooked_performAction(void* message, bool flag, void* attributedString, void* action) {
    if (orig_performAction) {
		NSLog(@"[Tweak] performTextSelectionAction called. Overriding flag to true.");
        orig_performAction(message, true, attributedString, action);
		NSLog(@"[Tweak] performTextSelectionAction completed.");
    } else {
		NSLog(@"[Tweak] performTextSelectionAction called but original function pointer is NULL!");
	}
}



// --- 2. The Objective-C Interception ---
// We hook the Node's initializer to capture the Swift Interaction object
static id (*orig_ChatControllerNode_init)(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4, id arg5);

id hooked_ChatControllerNode_init(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4, id arg5) {
    // 1. Let the original initialization happen
    id instance = orig_ChatControllerNode_init(self, _cmd, arg1, arg2, arg3, arg4, arg5);
    
    if (instance) {
		debug_print(@"[Tweak] ChatControllerNode initialized. Attempting to locate Interaction object…");
        // 2. Locate the controllerInteraction ivar inside ChatControllerNode
        Ivar nodeIvar = class_getInstanceVariable(objc_getClass("TelegramUI.ChatControllerNode"), "controllerInteraction");
        if (nodeIvar) {
			debug_print(@"[Tweak] Found controllerInteraction ivar at offset %lu", ivar_getOffset(nodeIvar));
            uintptr_t interactionInstance = *(uintptr_t *)((uintptr_t)instance + ivar_getOffset(nodeIvar));
            
            // 3. Locate the performTextSelectionAction ivar inside the Swift class
            Ivar swiftIvar = class_getInstanceVariable(objc_getClass("ChatControllerInteraction.ChatControllerInteraction"), "performTextSelectionAction");
            if (swiftIvar && interactionInstance) {
				debug_print(@"[Tweak] Found performTextSelectionAction ivar at offset %lu", ivar_getOffset(swiftIvar));
                void **funcPtrLocation = (void **)(interactionInstance + ivar_getOffset(swiftIvar));
                void *targetCode = *funcPtrLocation;

                // 4. Use Dobby to hook the actual Swift code
                // We only need to do this once for the lifetime of the process
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    if (targetCode) {
						debug_print(@"[Tweak] Original performTextSelectionAction located at %p. Installing hook…", targetCode);
                        DobbyHook(targetCode, (void *)hooked_performAction, (void **)&orig_performAction);
                        debug_print(@"[Tweak] Successfully hooked performTextSelectionAction at %p", targetCode);
                    } else {
						debug_print(@"[Tweak] performTextSelectionAction ivar is NULL!");
					}
                });
            } else {
				debug_print(@"[Tweak] Failed to find performTextSelectionAction ivar or interactionInstance is NULL!");
			}
        } else {
			debug_print(@"[Tweak] Failed to find controllerInteraction ivar!");
		}
    } else {
		debug_print(@"[Tweak] ChatControllerNode initializer returned nil!");
	}
    return instance;
}

@implementation NSObject (NodeHijack)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = objc_getClass("TelegramUI.ChatControllerNode");
		//debug_print(@"[Tweak] Attempting to hook ChatControllerNode…");
        if (!cls) return;

        // We hook 'didLoad' or 'init' - 'didLoad' is often safer in Telegram
        SEL targetSel = @selector(didLoad); 
        Method originalMethod = class_getInstanceMethod(cls, targetSel);
        
        void (*orig_didLoad)(id, SEL) = (void (*)(id, SEL))method_getImplementation(originalMethod);
        
        // Replacement block for didLoad
        void (^replacement)(id) = ^(id self) {
            orig_didLoad(self, targetSel); // Call original first

            // Grab the interaction object from the ivar
            Ivar interactionIvar = class_getInstanceVariable([self class], "controllerInteraction");
            if (interactionIvar) {
                uintptr_t interactionInstance = *(uintptr_t *)((uintptr_t)self + ivar_getOffset(interactionIvar));
                
                // Get the closure offset (we'll use ivar name to be safe)
                Ivar swiftIvar = class_getInstanceVariable(objc_getClass("ChatControllerInteraction.ChatControllerInteraction"), "performTextSelectionAction");
                if (swiftIvar && interactionInstance) {
                    void **funcPtrLoc = (void **)(interactionInstance + ivar_getOffset(swiftIvar));
                    
                    static dispatch_once_t hookOnce;
                    dispatch_once(&hookOnce, ^{
                        DobbyHook(*funcPtrLoc, (void *)hooked_performAction, (void **)&orig_performAction);
                        NSLog(@"[Tweak] Hooked performTextSelectionAction via didLoad!");
                    });
                }
            }
        };

        method_setImplementation(originalMethod, imp_implementationWithBlock(replacement));
    });
}
@end



static void initializeTweak() {
    debug_print(@"[Tweak] Loader injected. Setting up hooks...");

    // Hook the Objective-C initializer of the Node
    // We use Dobby here too, or you could use MSHookMessageEx if using Substrate
    Method m = class_getInstanceMethod(objc_getClass("TelegramUI.ChatControllerNode"), sel_registerName("initWithContext:tableAddress:controllerInteraction:interfaceInteraction:navigationController:"));
    
    if (m) {
        DobbyHook((void *)method_getImplementation(m), 
                  (void *)hooked_ChatControllerNode_init, 
                  (void **)&orig_ChatControllerNode_init);
        debug_print(@"[Tweak] ChatControllerNode hook installed.");
    } else {
        debug_print(@"[Tweak] Failed to find ChatControllerNode initializer.");
    }
}

static void init() {
	debug_print(@"Scanning all loaded classes…");

	initializeTweak();
	debug_print(@"Initialization complete.");
	return;

	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	if (!classes) {
		debug_print(@"objc_copyClassList returned nil");
		return;
	} else {
		debug_print(@"objc_copyClassList returned %u classes:", count);
		// Variable with list of interesting classes to look for (based on class-dump analysis):
		NSArray<NSString *> *interestingClasses = @[
			@"ChatControllerInteraction"
		];
		/*@[
			@"TGMessage", @"TGSecretMedia", @"TGCopyProtectionController", @"TGCopyProtectedMediaController",
			@"TGCachedConversationData", @"TGCachedMessageData", @"TGMessageViewModel", @"TGMessageCell",
			@"TGSecretMessageCell", @"TGMessageController", @"TGSecretMessageController"
		];*/
		for (unsigned int i = 0; i < count; i++) {
			// Only print classes with the name containing "Telegram", "TG", "Secret", "Message"
			Class cls = classes[i];
			NSString *className = [NSString stringWithUTF8String:class_getName(cls)];
			BOOL interesting = false;
			for (NSString *keyword in interestingClasses) {
				if ([className containsString:keyword]) {
					debug_print(@"[class]%@", className);
					interesting = true;
					break;
				}
			}
			if (!interesting) continue;
			debug_print(@"[class]%@", className);
			// properties
			unsigned int propCount = 0;
			objc_property_t *properties = class_copyPropertyList(cls, &propCount);
			if (properties) {
				for (unsigned int j = 0; j < propCount; j++) {
					objc_property_t p = properties[j];
					debug_print(@"[class:%s]  @property %s", class_getName(cls), property_getName(p));
				}
			}
			free(properties);
			// ivars
			unsigned int ivarCount = 0;
			Ivar *ivars = class_copyIvarList(cls, &ivarCount);
			if (ivars) {
				for (unsigned int j = 0; j < ivarCount; j++) {
					Ivar ivar = ivars[j];
					debug_print(@"[class:%s]  ivar %s", class_getName(cls), ivar_getName(ivar));
				}
			}
			free(ivars);
			// methods
			unsigned int methodCount = 0;
			Method *methods = class_copyMethodList(cls, &methodCount);
			if (methods) {
				for (unsigned int j = 0; j < methodCount; j++) {
					Method m = methods[j];
					debug_print(@"[class:%s]  - %s", class_getName(cls), sel_getName(method_getName(m)));
				}
			}
			free(methods);
		}
	}

	unsigned int hits = 0;
	for (unsigned int i = 0; i < count; i++) {
		Class cls = classes[i];
		BOOL match =
			class_getInstanceMethod(cls, @selector(isCopyProtected)) != NULL ||
			class_getInstanceMethod(cls, @selector(setCopyProtected:)) != NULL ||
			class_getInstanceMethod(cls, @selector(containsSecretMedia)) != NULL ||
			class_getInstanceMethod(cls, @selector(setContainsSecretMedia:)) != NULL ||
			class_getInstanceMethod(cls, @selector(copyProtectionEnabled)) != NULL ||
			class_getInstanceMethod(cls, @selector(setCopyProtectionEnabled:)) != NULL;

		if (match) {
			hookClass(cls);
			hits++;
		}
	}

	free(classes);
	debug_print(@"Done. Hooked %u class(es).", hits);
}

INITIALIZE("FindCopyProtected")
