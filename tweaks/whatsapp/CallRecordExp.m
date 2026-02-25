#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "fishhook.h"

// --- Function Pointers ---
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitProcess)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

// --- File Handles & Counters ---
static NSFileHandle *micFile = nil;
static NSFileHandle *speakerFile = nil;

static uint32_t totalMicBytes = 0;
static uint32_t totalSpeakerBytes = 0;
static uint32_t micChunkCount = 0;
static uint32_t speakerChunkCount = 0;

static double g_phase = 0.0;

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
void sealWavHeader(NSFileHandle *file, uint32_t currentBytes) {
    if (!file) return;
    @synchronized(file) {
        unsigned long long currentPos = [file offsetInFile];
        uint32_t anticipatedData = currentBytes + (100 * 4096); 
        uint32_t fileSizeField = anticipatedData + 44 - 8;
        [file seekToFileOffset:4];
        [file writeData:[NSData dataWithBytes:&fileSizeField length:4]];
        [file seekToFileOffset:40];
        [file writeData:[NSData dataWithBytes:&anticipatedData length:4]];
        [file seekToFileOffset:currentPos];
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

// --- Unified Recording Logic ---
void recordToWav(NSFileHandle *file, AudioBufferList *ioData, uint32_t *byteCounter, uint32_t *chunkCounter) {
    if (!file || !ioData) return;
    @synchronized(file) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            if (ioData->mBuffers[i].mData && ioData->mBuffers[i].mDataByteSize > 0) {
                [file writeData:[NSData dataWithBytes:ioData->mBuffers[i].mData length:ioData->mBuffers[i].mDataByteSize]];
                *byteCounter += (uint32_t)ioData->mBuffers[i].mDataByteSize;
                *chunkCounter += 1;
                if (*chunkCounter % 100 == 0) sealWavHeader(file, *byteCounter);
            }
        }
    }
}

// --- Hook 1: Speaker Callback Backup ---
static AURenderCallback orig_outputCallback = NULL;
OSStatus hooked_outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_outputCallback ? orig_outputCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) : noErr;
    if (status == noErr) recordToWav(speakerFile, ioData, &totalSpeakerBytes, &speakerChunkCount);
    return status;
}

// --- Hook 2: AudioUnitRender (Primary Mic & Speaker) ---
OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    if (status == noErr && ioData != NULL) {
        if (inBusNumber == 1) { 
            recordToWav(micFile, ioData, &totalMicBytes, &micChunkCount);
            // Spoof Mic
            for (int i = 0; i < ioData->mNumberBuffers; i++) {
                float *buffer = (float *)ioData->mBuffers[i].mData;
                for (UInt32 frame = 0; frame < (ioData->mBuffers[i].mDataByteSize / sizeof(float)); frame++) {
                    buffer[frame] = (float)sin(g_phase);
                    g_phase += 0.0628; if (g_phase > 6.28) g_phase -= 6.28;
                }
            }
        } else if (inBusNumber == 0) {
            recordToWav(speakerFile, ioData, &totalSpeakerBytes, &speakerChunkCount);
        }
    }
    return status;
}

// --- Hook 3: AudioUnitProcess (DSP Graph Data) ---
OSStatus hooked_AudioUnitProcess(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitProcess(inUnit, ioActionFlags, inTimeStamp, inNumberFrames, ioData);
    if (status == noErr) recordToWav(speakerFile, ioData, &totalSpeakerBytes, &speakerChunkCount);
    return status;
}

// --- Hook 4: Property Setter (Callback Interceptor) ---
OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback && inElement == 0) {
        AURenderCallbackStruct *cbStruct = (AURenderCallbackStruct *)inData;
        if (cbStruct->inputProc != hooked_outputCallback) {
            orig_outputCallback = cbStruct->inputProc;
            cbStruct->inputProc = hooked_outputCallback;
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

void setupFiles() {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    micFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"mic.wav"]];
    speakerFile = [NSFileHandle fileHandleForWritingAtPath:[docPath stringByAppendingPathComponent:@"speaker.wav"]];
    writeWavHeader(micFile); writeWavHeader(speakerFile);
}

__attribute__((constructor))
static void init() {
    setupFiles();
    struct rebinding rebs[] = {
        {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
        {"AudioUnitProcess", (void *)hooked_AudioUnitProcess, (void **)&orig_AudioUnitProcess},
        {"AudioUnitSetProperty", (void *)hooked_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty}
    };
    rebind_symbols(rebs, 3);
}
