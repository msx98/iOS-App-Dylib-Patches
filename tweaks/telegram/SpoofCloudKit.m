#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <math.h>
#import "fishhook.h"

// --- CLOUDKIT BYPASS TYPES & GLOBALS ---
typedef NS_ENUM(NSInteger, CKAccountStatus) {
    CKAccountStatusNoAccount = 3
};
typedef void (^CKAccountStatusBlock)(CKAccountStatus accountStatus, NSError *error);

// --- AUDIO GLOBALS ---
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static AURenderCallback orig_renderCallback = NULL;
static FILE *g_fileIn = NULL;
static FILE *g_fileOut = NULL;
static double g_phase = 0.0;

// --- CLOUDKIT BYPASS LOGIC ---
void Swizzle(Class c, SEL orig, IMP newImp) {
    Method m = class_getInstanceMethod(c, orig);
    if (m) method_setImplementation(m, newImp);
}

void hooked_accountStatus(id self, SEL _cmd, CKAccountStatusBlock completionHandler) {
    if (completionHandler) completionHandler(CKAccountStatusNoAccount, nil);
}

id hooked_nilReturn(id self, SEL _cmd) { return nil; }

static void init_cloudkit_bypass() {
    Class ckContainer = objc_getClass("CKContainer");
    if (ckContainer) {
        Swizzle(ckContainer, @selector(accountStatusWithCompletionHandler:), (IMP)hooked_accountStatus);
        Class ckMeta = object_getClass(ckContainer);
        Swizzle(ckMeta, @selector(containerWithIdentifier:), (IMP)hooked_nilReturn);
        Swizzle(ckMeta, @selector(defaultContainer), (IMP)hooked_nilReturn);
        NSLog(@"[MicSpoof] CloudKit Bypass Active.");
    }
}

// --- AUDIO HOOKS ---
OSStatus hooked_renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_renderCallback ? orig_renderCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) : noErr;
    if (status == noErr && ioData != NULL && g_fileOut) {
        for (int i=0; i < ioData->mNumberBuffers; i++) {
            fwrite(ioData->mBuffers[i].mData, 1, ioData->mBuffers[i].mDataByteSize, g_fileOut);
        }
    }
    return status;
}

// --- CONSTRUCTOR ---
__attribute__((constructor))
static void init() {
    init_cloudkit_bypass();
    NSLog(@"[MicSpoof] All hooks initialized.");
}
