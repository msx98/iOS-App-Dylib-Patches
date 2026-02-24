#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "fishhook.h"
#define FIX_HEADER_PERIOD 100

static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static NSFileHandle *micFile = nil;
static NSFileHandle *speakerFile = nil;

static uint32_t totalMicBytes = 0;
static uint32_t totalSpeakerBytes = 0;
static uint32_t totalMicBytesLast = 0;
static uint32_t totalSpeakerBytesLast = 0;

// --- WAV Header (44 Bytes) ---
typedef struct {
    char     riff[4];
    uint32_t fileSize;
    char     wave[4];
    char     fmt[4];
    uint32_t fmtLen;
    uint16_t format;       // 3 = IEEE Float
    uint16_t channels;     // 1 = Mono
    uint32_t sampleRate;   // 25000 
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char     data[4];
    uint32_t dataLen;
} WavHeader;

// --- Periodic Header Update ---
void sealWavHeader(NSFileHandle *file, uint32_t *currentBytes, uint32_t *currentBytesLast) {
    if (!file) return;
    @synchronized(file) {
        unsigned long long currentPos = [file offsetInFile];
        uint32_t anticipatedData = *currentBytes + (FIX_HEADER_PERIOD * 4096); 
        uint32_t fileSizeField = anticipatedData + 44 - 8;
        [file seekToFileOffset:4];
        [file writeData:[NSData dataWithBytes:&fileSizeField length:4]];
        [file seekToFileOffset:40];
        [file writeData:[NSData dataWithBytes:&anticipatedData length:4]];
        [file seekToFileOffset:currentPos];
        *currentBytesLast = currentPos;
    }
}

void writeWavHeader(NSFileHandle *file) {
    WavHeader h;
    memcpy(h.riff, "RIFF", 4); memcpy(h.wave, "WAVE", 4); memcpy(h.fmt, "fmt ", 4);
    h.fmtLen = 16; h.format = 3; h.channels = 1; h.sampleRate = 25000; h.bitsPerSample = 32;
    h.byteRate = h.sampleRate * h.channels * (h.bitsPerSample / 8);
    h.blockAlign = h.channels * (h.bitsPerSample / 8);
    memcpy(h.data, "data", 4); h.fileSize = 0xFFFFFFFF; h.dataLen = 0xFFFFFFFF;
    [file writeData:[NSData dataWithBytes:&h length:sizeof(WavHeader)]];
}

void appendAudio(NSFileHandle *file, uint32_t *totalBytes, uint32_t *totalBytesLast, AudioBufferList *ioData) {
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        [file writeData:[NSData dataWithBytes:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize]];
        *totalBytes += ioData->mBuffers[i].mDataByteSize;
    }
    if ((*totalBytes) - (*totalBytesLast) > FIX_HEADER_PERIOD) {
        sealWavHeader(file, totalBytes, totalBytesLast);
    }
}

void setupFiles() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    micFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"mic.bin"]];
    speakerFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"speaker.bin"]];
}

// Intercept the app's output callback (The Speaker)
static AURenderCallback orig_outputCallback = NULL;
OSStatus hooked_outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = noErr;
    if (orig_outputCallback) {
        status = orig_outputCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    if (status == noErr && ioData != NULL) {
        appendAudio(speakerFile, &totalSpeakerBytes, &totalSpeakerBytesLast, ioData);
    }
    return status;
}

OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    
    if (status == noErr && ioData != NULL) {
        if (inBusNumber == 1) { 
            appendAudio(micFile, &totalMicBytes, &totalMicBytesLast, ioData);
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
