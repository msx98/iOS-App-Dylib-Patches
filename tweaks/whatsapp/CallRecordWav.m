#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "fishhook.h"

#define FIX_HEADER_PERIOD_BYTES (1024 * 512) // Update header every 512KB

#pragma pack(push, 1)
typedef struct {
    char     riff[4];
    uint32_t fileSize;
    char     wave[4];
    char     fmt[4];
    uint32_t fmtLen;
    uint16_t format;        // 3 = IEEE Float (f32le)
    uint16_t channels;
    uint32_t sampleRate;
    uint32_t byteRate;
    uint16_t blockAlign;
    uint16_t bitsPerSample;
    char     data[4];
    uint32_t dataLen;
} WavHeader;
#pragma pack(pop)

typedef struct {
    __unsafe_unretained NSFileHandle *fileHandle;
    uint32_t totalDataBytes;
    uint32_t lastCommittedBytes;
    BOOL isInitialized;
} WavRecorder;

// --- Globals ---
static WavRecorder micRecorder;
static WavRecorder speakerRecorder;
static AudioStreamBasicDescription capturedASBD;

static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static AURenderCallback orig_outputCallback = NULL;

// --- Core Logic ---

void updateWavHeader(WavRecorder *recorder) {
    if (!recorder->fileHandle) return;
    
    uint32_t dataSize = recorder->totalDataBytes;
    uint32_t totalFileSize = dataSize + sizeof(WavHeader) - 8;
    
    unsigned long long currentPos = [recorder->fileHandle offsetInFile];
    
    // Offset 4: RIFF chunk size
    [recorder->fileHandle seekToFileOffset:4];
    [recorder->fileHandle writeData:[NSData dataWithBytes:&totalFileSize length:4]];
    
    // Offset 40: data chunk size
    [recorder->fileHandle seekToFileOffset:40];
    [recorder->fileHandle writeData:[NSData dataWithBytes:&dataSize length:4]];
    
    [recorder->fileHandle seekToFileOffset:currentPos];
    recorder->lastCommittedBytes = dataSize;
    [recorder->fileHandle synchronizeFile];
}

void writeInitialHeader(NSFileHandle *handle) {
    WavHeader h;
    memcpy(h.riff, "RIFF", 4);
    memcpy(h.wave, "WAVE", 4);
    memcpy(h.fmt,  "fmt ", 4);
    
    h.fmtLen = 16;
    h.format = 3; // f32le
    
    // Use captured ASBD from the app or fallback to your 24k test
    h.sampleRate = (capturedASBD.mSampleRate > 0) ? (uint32_t)capturedASBD.mSampleRate : 24000;
    h.channels = (capturedASBD.mChannelsPerFrame > 0) ? (uint16_t)capturedASBD.mChannelsPerFrame : 1;
    h.bitsPerSample = 32;
    
    h.byteRate = h.sampleRate * h.channels * (h.bitsPerSample / 8);
    h.blockAlign = h.channels * (h.bitsPerSample / 8);
    
    memcpy(h.data, "data", 4);
    h.fileSize = 0;
    h.dataLen = 0;
    
    [handle writeData:[NSData dataWithBytes:&h length:sizeof(WavHeader)]];
}

NSFileHandle* createCaptureFile(NSString *fileName) {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [docPath stringByAppendingPathComponent:fileName];
    
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    
    if (handle) {
        writeInitialHeader(handle);
        NSLog(@"[CallRecord] Created file: %@", path);
    }
    return handle;
}

void appendAudio(WavRecorder *recorder, AudioBufferList *ioData, NSString *defaultName) {
    if (!recorder->isInitialized) {
        recorder->fileHandle = createCaptureFile(defaultName);
        recorder->isInitialized = YES;
    }
    
    if (!recorder->fileHandle || !ioData) return;
    
    @synchronized(recorder->fileHandle) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            UInt32 len = ioData->mBuffers[i].mDataByteSize;
            if (len > 0 && ioData->mBuffers[i].mData != NULL) {
                NSData *data = [NSData dataWithBytesNoCopy:ioData->mBuffers[i].mData length:len freeWhenDone:NO];
                [recorder->fileHandle writeData:data];
                recorder->totalDataBytes += len;
            }
        }
        
        // Periodic commit so files work if app crashes
        if (recorder->totalDataBytes - recorder->lastCommittedBytes > FIX_HEADER_PERIOD_BYTES) {
            updateWavHeader(recorder);
        }
    }
}

// --- Hooks ---

static OSStatus hooked_outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = noErr;
    if (orig_outputCallback) {
        status = orig_outputCallback(inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    
    if (status == noErr && ioData != NULL) {
        appendAudio(&speakerRecorder, ioData, @"speaker.wav");
    }
    return status;
}

static OSStatus hooked_AudioUnitRender(AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    
    // Bus 1 is typically the Input (Mic)
    if (status == noErr && inBusNumber == 1 && ioData != NULL) {
        appendAudio(&micRecorder, ioData, @"mic.wav");
    }
    return status;
}

static OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    
    if (inID == kAudioUnitProperty_StreamFormat) {
        if (inData && inDataSize >= sizeof(AudioStreamBasicDescription)) {
            AudioStreamBasicDescription *asbd = (AudioStreamBasicDescription *)inData;
            capturedASBD = *asbd;
            NSLog(@"[CallRecord] Captured ASBD: %f Hz, %d ch", asbd->mSampleRate, asbd->mChannelsPerFrame);
        }
    }
    
    if (inID == kAudioUnitProperty_SetRenderCallback) {
        if (inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
            AURenderCallbackStruct *cbStruct = (AURenderCallbackStruct *)inData;
            if (cbStruct->inputProc != NULL && cbStruct->inputProc != hooked_outputCallback) {
                orig_outputCallback = cbStruct->inputProc;
                cbStruct->inputProc = hooked_outputCallback;
                NSLog(@"[CallRecord] Output Callback Hooked Successfully");
            }
        }
    }
    
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

__attribute__((constructor))
static void init() {
    rebind_symbols((struct rebinding[2]){
        {"AudioUnitRender", (void *)hooked_AudioUnitRender, (void **)&orig_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)hooked_AudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty}
    }, 2);
}
