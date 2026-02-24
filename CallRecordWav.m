#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "fishhook.h"

#define FIX_HEADER_PERIOD_BYTES (1024 * 100) // Update header every 100KB

// --- Improved Structs ---
#pragma pack(push, 1)
typedef struct {
    char     riff[4];        // "RIFF"
    uint32_t fileSize;       // Total file size - 8
    char     wave[4];        // "WAVE"
    char     fmt[4];         // "fmt "
    uint32_t fmtLen;         // 16 for PCM
    uint16_t format;         // 3 = IEEE Float, 1 = PCM
    uint16_t channels;       // 1 = Mono
    uint32_t sampleRate;     // e.g., 24000
    uint32_t byteRate;       // sampleRate * channels * (bitsPerSample/8)
    uint16_t blockAlign;     // channels * (bitsPerSample/8)
    uint16_t bitsPerSample;  // 32 for float
    char     data[4];        // "data"
    uint32_t dataLen;        // Actual audio data size
} WavHeader;
#pragma pack(pop)

typedef struct {
    __unsafe_unretained NSFileHandle *fileHandle;
    uint32_t totalDataBytes;
    uint32_t lastCommittedBytes;
} WavRecorder;

// Static instances for Mic and Speaker
static WavRecorder micRecorder;
static WavRecorder speakerRecorder;

// --- Function Pointers for Hooks ---
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static AURenderCallback orig_outputCallback = NULL;

// --- Implementation ---

void updateWavHeader(WavRecorder *recorder) {
    if (!recorder->fileHandle) return;
    
    uint32_t dataSize = recorder->totalDataBytes;
    uint32_t totalFileSize = dataSize + sizeof(WavHeader) - 8;
    
    unsigned long long currentPos = [recorder->fileHandle offsetInFile];
    
    // Seek to fileSize (offset 4)
    [recorder->fileHandle seekToFileOffset:4];
    [recorder->fileHandle writeData:[NSData dataWithBytes:&totalFileSize length:4]];
    
    // Seek to dataLen (offset 40)
    [recorder->fileHandle seekToFileOffset:40];
    [recorder->fileHandle writeData:[NSData dataWithBytes:&dataSize length:4]];
    
    [recorder->fileHandle seekToFileOffset:currentPos];
    recorder->lastCommittedBytes = dataSize;
    
    // Force OS to flush buffers to disk
    [recorder->fileHandle synchronizeFile];
}

void writeInitialHeader(NSFileHandle *file) {
    WavHeader h;
    memcpy(h.riff, "RIFF", 4);
    memcpy(h.wave, "WAVE", 4);
    memcpy(h.fmt,  "fmt ", 4);
    
    h.fmtLen = 16;
    h.format = 3;           // 3 = IEEE Float (Standard for AudioUnit buffers)
    h.channels = 1; 
    h.sampleRate = 24000;   // Ensure this matches your AudioUnit settings
    h.bitsPerSample = 32;
    h.byteRate = h.sampleRate * h.channels * (h.bitsPerSample / 8);
    h.blockAlign = h.channels * (h.bitsPerSample / 8);

    memcpy(h.data, "data", 4);
    h.fileSize = 0; // Will be updated by updateWavHeader
    h.dataLen = 0;  // Will be updated by updateWavHeader
    
    [file writeData:[NSData dataWithBytes:&h length:sizeof(WavHeader)]];
}

void appendAudio(WavRecorder *recorder, AudioBufferList *ioData) {
    if (!recorder->fileHandle || !ioData) return;
    
    @synchronized(recorder->fileHandle) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            UInt32 len = ioData->mBuffers[i].mDataByteSize;
            if (len == 0) continue;
            
            NSData *data = [NSData dataWithBytesNoCopy:ioData->mBuffers[i].mData length:len freeWhenDone:NO];
            [recorder->fileHandle writeData:data];
            recorder->totalDataBytes += len;
        }
        
        // Periodic commit
        if (recorder->totalDataBytes - recorder->lastCommittedBytes > FIX_HEADER_PERIOD_BYTES) {
            updateWavHeader(recorder);
        }
    }
}

// --- Hooks ---

OSStatus hooked_outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_outputCallback ? orig_outputCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) : noErr;
    if (status == noErr && ioData) {
        appendAudio(&speakerRecorder, ioData);
    }
    return status;
}

OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    // Bus 1 is typically the Input/Mic bus
    if (status == noErr && inBusNumber == 1 && ioData) {
        appendAudio(&micRecorder, ioData);
    }
    return status;
}

OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback) {
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
    
    for (NSString *name in @[@"mic.wav", @"speaker.wav"]) {
        NSString *path = [docPath stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            writeInitialHeader(handle);
            if ([name containsString:@"mic"]) {
                micRecorder.fileHandle = handle;
            } else {
                speakerRecorder.fileHandle = handle;
            }
        }
    }
}

__attribute__((constructor))
static void init() {
    setupFiles();
    rebind_symbols((struct rebinding[2]){
        {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)hooked_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty}
    }, 2);
}
