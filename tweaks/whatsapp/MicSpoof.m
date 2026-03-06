#import "fishhook.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <math.h>

#include "../../lib/utils/utils.m"

// Pointers for original functions
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *);
static OSStatus (*orig_AudioUnitProcess)(AudioUnit,
                                         AudioUnitRenderActionFlags *,
                                         const AudioTimeStamp *, UInt32,
                                         AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                             AudioUnitScope, AudioUnitElement,
                                             const void *, UInt32);
static OSStatus (*orig_AudioUnitAddRenderNotify)(AudioUnit, AURenderCallback,
                                                 void *);
static FILE *g_fileMic = NULL;
static FILE *g_fileSpeaker = NULL;
static double g_phase = 0.0;
static AURenderCallback orig_renderCallback = NULL;

// --- FALLBACK: Render Notify Observer ---
// This is called by the system BEFORE and AFTER every render cycle.
static OSStatus MyRenderNotify(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber, UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
  // We only care about AFTER the render (post-render) when ioData is filled
  if (*ioActionFlags & kAudioUnitRenderAction_PostRender) {
    if (ioData != NULL && inBusNumber == 0 && g_fileSpeaker) {
      for (int i = 0; i < ioData->mNumberBuffers; i++) {
        fwrite(ioData->mBuffers[i].mData, 1, ioData->mBuffers[i].mDataByteSize,
               g_fileSpeaker);
      }
    }
  }
  return noErr;
}

// --- UNIVERSAL CALLBACK INTERCEPTOR ---
OSStatus hooked_renderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber, UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
  OSStatus status = noErr;
  if (orig_renderCallback) {
    status = orig_renderCallback(inRefCon, ioActionFlags, inTimeStamp,
                                 inBusNumber, inNumberFrames, ioData);
  }
  if (status == noErr && ioData != NULL && g_fileSpeaker) {
    // Force capture any data pulled by the system
    for (int i = 0; i < ioData->mNumberBuffers; i++) {
      if (ioData->mBuffers[i].mDataByteSize > 0) {
        fwrite(ioData->mBuffers[i].mData, 1, ioData->mBuffers[i].mDataByteSize,
               g_fileSpeaker);
      }
    }
  }
  return status;
}

// --- HOOK: AudioUnitSetProperty ---
static OSStatus
hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID,
                            AudioUnitScope inScope, AudioUnitElement inElement,
                            const void *inData, UInt32 inDataSize) {
  // Always add a Render Notify to every unit created to ensure we see its data
  // orig_AudioUnitAddRenderNotify(inUnit, MyRenderNotify, NULL);
  if (inID == kAudioUnitProperty_SetRenderCallback || inID == 2005) {
    if (inDataSize >= sizeof(AURenderCallbackStruct)) {
      AURenderCallbackStruct *cb = (AURenderCallbackStruct *)inData;
      /*if (cb->inputProc != NULL && cb->inputProc != hooked_renderCallback) {
        orig_renderCallback = cb->inputProc;
        cb->inputProc = hooked_renderCallback;
      }*/
    }
  }
  return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData,
                                   inDataSize);
}

// --- HOOK: AudioUnitRender (Mic Spoofing) ---

OSStatus hooked_AudioUnitRender(AudioUnit inUnit,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber, UInt32 inNumberFrames,
                                AudioBufferList *ioData) {
  OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp,
                                         inBusNumber, inNumberFrames, ioData);
  return status;
  if (status == noErr && ioData != NULL) {
    if (inBusNumber == 1) {
      if (g_fileMic)
        fwrite(ioData->mBuffers[0].mData, 1, ioData->mBuffers[0].mDataByteSize,
               g_fileMic);
      float *buf = (float *)ioData->mBuffers[0].mData;
    }
  }
  return status;
}

static void init() {
  NSString *doc =
      [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  g_fileMic = fopen(
      [[doc stringByAppendingPathComponent:@"mic_in.bin"] UTF8String], "wb");
  g_fileSpeaker = fopen(
      [[doc stringByAppendingPathComponent:@"app_out.bin"] UTF8String], "wb");
  debug_print(@"[MicSpoof] Output files opened: mic_in.bin, app_out.bin");
  orig_AudioUnitRender = dlsym(RTLD_NEXT, "AudioUnitRender");
  orig_AudioUnitSetProperty = dlsym(RTLD_NEXT, "AudioUnitSetProperty");
  orig_AudioUnitAddRenderNotify = dlsym(RTLD_NEXT, "AudioUnitAddRenderNotify");
  /*rebind_symbols(
      (struct rebinding[2]){{"AudioUnitRender", hooked_AudioUnitRender,
                             (void *)&orig_AudioUnitRender},
                            {"AudioUnitSetProperty",
                             hooked_AudioUnitSetProperty,
                             (void *)&orig_AudioUnitSetProperty}},
      2);*/
}

INITIALIZE("MicSpoof")
