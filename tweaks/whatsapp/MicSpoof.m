#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import "fishhook.h"

// Pointers for original functions
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitProcess)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static FILE *g_fileIn = NULL;
static FILE *g_fileOut = NULL;
static double g_phase = 0.0;
static AURenderCallback orig_renderCallback = NULL;

// --- FALLBACK: Render Notify Observer ---
// This is called by the system BEFORE and AFTER every render cycle.
static OSStatus MyRenderNotify(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    // We only care about AFTER the render (post-render) when ioData is filled
    if (*ioActionFlags & kAudioUnitRenderAction_PostRender) {
        if (ioData != NULL && inBusNumber == 0 && g_fileOut) {
            for (int i=0; i < ioData->mNumberBuffers; i++) {
                fwrite(ioData->mBuffers[i].mData, 1, ioData->mBuffers[i].mDataByteSize, g_fileOut);
            }
        }
    }
    return noErr;
}

// --- UNIVERSAL CALLBACK INTERCEPTOR ---
OSStatus hooked_renderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = noErr;
    if (orig_renderCallback) {
        status = orig_renderCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    if (status == noErr && ioData != NULL && g_fileOut) {
        // Force capture any data pulled by the system
        for (int i=0; i < ioData->mNumberBuffers; i++) {
            if (ioData->mBuffers[i].mDataByteSize > 0) {
                fwrite(ioData->mBuffers[i].mData, 1, ioData->mBuffers[i].mDataByteSize, g_fileOut);
            }
        }
    }
    return status;
}

// --- HOOK: AudioUnitSetProperty ---
OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    // Always add a Render Notify to every unit created to ensure we see its data
    AudioUnitAddRenderNotify(inUnit, MyRenderNotify, NULL);

    if (inID == kAudioUnitProperty_SetRenderCallback || inID == 2005) {
        if (inDataSize >= sizeof(AURenderCallbackStruct)) {
            AURenderCallbackStruct *cb = (AURenderCallbackStruct *)inData;
            if (cb->inputProc != NULL && cb->inputProc != hooked_renderCallback) {
                orig_renderCallback = cb->inputProc;
                cb->inputProc = hooked_renderCallback;
            }
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

// --- HOOK: AudioUnitRender (Mic Spoofing) ---
OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && ioData != NULL && inBusNumber == 1) {
        if (g_fileIn) fwrite(ioData->mBuffers[0].mData, 1, ioData->mBuffers[0].mDataByteSize, g_fileIn);
        float *buf = (float *)ioData->mBuffers[0].mData;
        for (UInt32 f = 0; f < ioData->mBuffers[0].mDataByteSize/4; f++) {
            buf[f] = (float)sin(g_phase);
            g_phase += 0.0628; if (g_phase > 6.28) g_phase -= 6.28;
        }
    }
    return status;
}

__attribute__((constructor))
static void init() {
    NSString *doc = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    g_fileIn = fopen([[doc stringByAppendingPathComponent:@"mic_in.bin"] UTF8String], "wb");
    g_fileOut = fopen([[doc stringByAppendingPathComponent:@"app_out.bin"] UTF8String], "wb");

    rebind_symbols((struct rebinding[]){
        {"AudioUnitRender", hooked_AudioUnitRender, (void *)&orig_AudioUnitRender},
        {"AudioUnitSetProperty", hooked_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty}
    }, 2);
}
