#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdio.h>
#import <time.h>

/**
 * CallDebug_Final_Fixed.m
 * Fixed property IDs and optimized for aggressive flushing.
 */

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static FILE *logFile = NULL;

// Helper to convert OSType (like 'vproc') to a string
char* OSTypeToString(OSType type) {
    static char str[5];
    *(UInt32 *)str = CFSwapInt32HostToBig(type);
    str[4] = '\0';
    return str;
}

// --- 1. The Callback ---
static OSStatus MyRenderNotify(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    
    if (!logFile) return noErr;

    if (*ioActionFlags & kAudioUnitRenderAction_PostRender) {
        if (ioData != NULL && ioData->mNumberBuffers > 0) {
            UInt32 size = ioData->mBuffers[0].mDataByteSize;
            
            // Log everything immediately
            fprintf(logFile, "[%ld] DATA: Bus %u | Size %u | Frames %u\n", 
                    time(NULL), (unsigned int)inBusNumber, (unsigned int)size, (unsigned int)inNumberFrames);
            fflush(logFile); 
        }
    } 
    return noErr;
}

// --- 2. The Initialization Hook ---
static OSStatus wrapped_AudioUnitInitialize(AudioUnit inUnit) {
    if (logFile) {
        AudioComponentDescription desc = {0};
        UInt32 size = sizeof(desc);
        
        // Use the NodeComponentDescription property which is available in your SDK
        OSStatus propStatus = AudioUnitGetProperty(inUnit, 
                                                   kAudioOutputUnitProperty_NodeComponentDescription, 
                                                   kAudioUnitScope_Global, 
                                                   0, 
                                                   &desc, 
                                                   &size);
        
        if (propStatus == noErr) {
            fprintf(logFile, "[%ld] Init: Subtype %s (Type: %s)\n", 
                    time(NULL), OSTypeToString(desc.componentSubType), OSTypeToString(desc.componentType));
        } else {
            fprintf(logFile, "[%ld] Init: Unit detected (ID query failed)\n", time(NULL));
        }
        fflush(logFile);
    }
    
    AudioUnitAddRenderNotify(inUnit, MyRenderNotify, NULL);
    return AudioUnitInitialize(inUnit);
}

DYLD_INTERPOSE(wrapped_AudioUnitInitialize, AudioUnitInitialize)

__attribute__((constructor))
static void init() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *logPath = [[paths firstObject] stringByAppendingPathComponent:@"CallDebugLog.txt"];
    
    logFile = fopen([logPath UTF8String], "a");
    if (logFile) {
        fprintf(logFile, "\n--- SESSION START: %ld ---\n", time(NULL));
        fflush(logFile);
    }
}
