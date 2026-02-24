#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "fishhook.h"

static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static NSFileHandle *micFile = nil;
static NSFileHandle *speakerFile = nil;
static NSFileHandle *speakerFile2 = nil;
static double g_phase = 0.0;

void setupFiles() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    micFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"mic.bin"]];
    speakerFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"speaker.bin"]];
    speakerFile2 = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"speaker2.bin"]];
}

// Intercept the app's output callback (The Speaker)
static AURenderCallback orig_outputCallback = NULL;
OSStatus hooked_outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = noErr;
    if (orig_outputCallback) {
        status = orig_outputCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    if (status == noErr && ioData != NULL) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            [speakerFile writeData:[NSData dataWithBytes:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize]];
        }
    }
    return status;
}

OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    
    if (status == noErr && ioData != NULL) {
        if (inBusNumber == 1) { 
            // 1. CAPTURE REAL MIC DATA FIRST
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                [micFile writeData:[NSData dataWithBytes:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize]];
            }
            
            // 2. NOW SPOOF (The "Beeps" the other person hears)
            /*for (int i = 0; i < ioData->mNumberBuffers; i++) {
                float *buffer = (float *)ioData->mBuffers[i].mData;
                for (UInt32 frame = 0; frame < (ioData->mBuffers[i].mDataByteSize / sizeof(float)); frame++) {
                    buffer[frame] = (float)sin(g_phase);
                    g_phase += 0.0628; 
                    if (g_phase > 6.28) g_phase -= 6.28;
                }
            }*/
        } else if (inBusNumber == 0) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            [speakerFile2 writeData:[NSData dataWithBytes:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize]];
        }
}
    }
    return status;
}

OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback) {
        AURenderCallbackStruct *cbStruct = (AURenderCallbackStruct *)inData;
        if (cbStruct->inputProc != hooked_outputCallback) {
            orig_outputCallback = cbStruct->inputProc;
            cbStruct->inputProc = hooked_outputCallback;
            NSLog(@"[CallRecord] Speaker Callback Hooked");
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

__attribute__((constructor))
static void init() {
    setupFiles();
    rebind_symbols((struct rebinding[2]){
        {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)hooked_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty}
    }, 2);
}
