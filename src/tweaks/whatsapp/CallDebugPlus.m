#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/log.h>

/**
 * CallDebugPlus.m
 * Hooks AudioUnitSetProperty to see the format (ASBD)
 * and AudioUnitRender to see the actual data flow.
 */

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{const void* replacement;const void* replacee;} _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = {(const void*)(unsigned long)&_replacement,(const void*)(unsigned long)&_replacee};

// --- 1. Hook for Format Detection ---
OSStatus wrapped_AudioUnitSetProperty(AudioUnit inUnit,
                                     AudioUnitPropertyID inID,
                                     AudioUnitScope inScope,
                                     AudioUnitElement inElement,
                                     const void *inData,
                                     UInt32 inDataSize) {
    
    // Check if the app is setting the Stream Format (ASBD)
    if (inID == kAudioUnitProperty_StreamFormat && inData != NULL) {
        AudioStreamBasicDescription *asbd = (AudioStreamBasicDescription *)inData;
        
        char formatID[5] = {0};
        *(UInt32 *)formatID = CFSwapInt32HostToBig(asbd->mFormatID);
        
        os_log(OS_LOG_DEFAULT, "[CallDebug] FORMAT DETECTED:");
        os_log(OS_LOG_DEFAULT, " >> SampleRate: %.0f | Format: %s | Channels: %u", 
               asbd->mSampleRate, formatID, (unsigned int)asbd->mChannelsPerFrame);
        os_log(OS_LOG_DEFAULT, " >> Bits/Channel: %u | Bytes/Frame: %u", 
               (unsigned int)asbd->mBitsPerChannel, (unsigned int)asbd->mBytesPerFrame);
    }
    
    return AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

// --- 2. Hook for Data Flow (Same as before) ---
OSStatus wrapped_AudioUnitRender(AudioUnit inUnit,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inOutputBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    
    OSStatus status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    
    if (status == noErr && ioData != NULL) {
        const char *dir = (inOutputBusNumber == 0) ? "SPEAKER" : "MIC";
        os_log(OS_LOG_DEFAULT, "[CallDebug] [%{public}s] Rendered %u frames (%u bytes)", 
               dir, (unsigned int)inNumberFrames, (unsigned int)ioData->mBuffers[0].mDataByteSize);
    }
    return status;
}

DYLD_INTERPOSE(wrapped_AudioUnitSetProperty, AudioUnitSetProperty)
DYLD_INTERPOSE(wrapped_AudioUnitRender, AudioUnitRender)

__attribute__((constructor))
static void init_CallDebugPlus() {
    os_log(OS_LOG_DEFAULT, "[CallDebug] Advanced Interposer Loaded.");
}
