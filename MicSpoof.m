#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import "fishhook.h" // You must include fishhook.c/h in your build

// Pointer to store the real, original system function
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static double g_phase = 0.0;
static const double kFrequency = 440.0;
static const double kSampleRate = 44100.0;

// This is our replacement function that the system will call instead
OSStatus hooked_AudioUnitRender(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData) 
{
    // 1. Call the real system function to fill the buffer with actual mic data
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);

    // 2. Detect if this is the Microphone Bus (Bus 1) providing input
    // and if the status is successful (noErr)
    if (status == noErr && inBusNumber == 1 && ioData != NULL) {
        
        for (int i = 0; i < ioData->mNumberBuffers; i++) {
            // Most modern iOS audio uses Float32 (Linear PCM)
            float *buffer = (float *)ioData->mBuffers[i].mData;
            UInt32 size = ioData->mBuffers[i].mDataByteSize / sizeof(float);

            for (UInt32 frame = 0; frame < size; frame++) {
                // Overwrite the real mic data with a sine wave
                buffer[frame] = (float)sin(g_phase);
                g_phase += 2.0 * M_PI * kFrequency / kSampleRate;
                if (g_phase > 2.0 * M_PI) g_phase -= 2.0 * M_PI;
            }
        }
    }
    return status;
}

__attribute__((constructor))
static void init() {
    NSLog(@"[MicSpoof] Fishhook: Rebinding AudioUnitRender...");

    // Rebind the system symbol 'AudioUnitRender' to our 'hooked_AudioUnitRender'
    rebind_symbols((struct rebinding[1]){
        {"AudioUnitRender", hooked_AudioUnitRender, (void *)&orig_AudioUnitRender}
    }, 1);

    NSLog(@"[MicSpoof] Hook Complete. Ready for calls.");
}
