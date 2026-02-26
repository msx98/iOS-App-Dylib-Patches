#import "fishhook.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "../../lib/utils/utils.m"

#define FIX_HEADER_PERIOD_BYTES (1024 * 512) // Update header every 512KB

#pragma pack(push, 1)
typedef struct {
  char riff[4];
  uint32_t fileSize;
  char wave[4];
  char fmt[4];
  uint32_t fmtLen;
  uint16_t format; // 3 = IEEE Float (f32le)
  uint16_t channels;
  uint32_t sampleRate;
  uint32_t byteRate;
  uint16_t blockAlign;
  uint16_t bitsPerSample;
  char data[4];
  uint32_t dataLen;
} WavHeader;
#pragma pack(pop)

typedef struct {
  __unsafe_unretained NSFileHandle *fileHandle;
  uint32_t totalDataBytes;
  uint32_t lastCommittedBytes;
  BOOL isInitialized;
} WavRecorder;

typedef struct {
  BOOL isActive;
  NSString *peerID;    // phone-number JID user part, set before connected
  NSString *timestamp; // set at connect time
} CallInfo;

// --- Globals ---
static WavRecorder micRecorder;
static WavRecorder speakerRecorder;
static AudioStreamBasicDescription capturedASBD;
static CallInfo g_callInfo;

static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *);
static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                             AudioUnitScope, AudioUnitElement,
                                             const void *, UInt32);
static OSStatus (*orig_AudioOutputUnitStart)(AudioUnit);

// --- Core Logic ---

static void updateWavHeader(WavRecorder *recorder) {
  if (!recorder->fileHandle)
    return;
  uint32_t dataSize = recorder->totalDataBytes;
  uint32_t totalFileSize = dataSize + sizeof(WavHeader) - 8;
  unsigned long long pos = [recorder->fileHandle offsetInFile];
  [recorder->fileHandle seekToFileOffset:4];
  [recorder->fileHandle writeData:[NSData dataWithBytes:&totalFileSize
                                                 length:4]];
  [recorder->fileHandle seekToFileOffset:40];
  [recorder->fileHandle writeData:[NSData dataWithBytes:&dataSize length:4]];
  [recorder->fileHandle seekToFileOffset:pos];
  recorder->lastCommittedBytes = dataSize;
  [recorder->fileHandle synchronizeFile];
}

static void writeInitialHeader(NSFileHandle *handle) {
  WavHeader h;
  memcpy(h.riff, "RIFF", 4);
  memcpy(h.wave, "WAVE", 4);
  memcpy(h.fmt, "fmt ", 4);
  h.fmtLen = 16;
  h.format = 3; // f32le
  h.sampleRate =
      capturedASBD.mSampleRate > 0 ? (uint32_t)capturedASBD.mSampleRate : 16000;
  h.channels = capturedASBD.mChannelsPerFrame > 0
                   ? (uint16_t)capturedASBD.mChannelsPerFrame
                   : 1;
  h.bitsPerSample = 32;
  h.byteRate = h.sampleRate * h.channels * (h.bitsPerSample / 8);
  h.blockAlign = h.channels * (h.bitsPerSample / 8);
  memcpy(h.data, "data", 4);
  h.fileSize = 0;
  h.dataLen = 0;
  [handle writeData:[NSData dataWithBytes:&h length:sizeof(WavHeader)]];
}

static NSFileHandle *createCaptureFile(NSString *suffix) {
  NSString *docPath = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *dirPath = [[[docPath stringByAppendingPathComponent:@"CallRecord"]
      stringByAppendingPathComponent:(g_callInfo.peerID ?: @"unknown")] copy];
  [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSString *path = [dirPath
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@_%@.wav",
                                                          g_callInfo.timestamp
                                                              ?: @"unknown",
                                                          suffix]];
  [[NSFileManager defaultManager] createFileAtPath:path
                                          contents:nil
                                        attributes:nil];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (handle) {
    writeInitialHeader(handle);
    debug_print(@"[CallRecordWav] Recording → %@", path);
  }
  return handle;
}

static void appendAudio(WavRecorder *recorder, AudioBufferList *ioData,
                        NSString *suffix) {
  if (!g_callInfo.isActive || !ioData)
    return;
  if (!recorder->isInitialized) {
    recorder->fileHandle = createCaptureFile(suffix);
    recorder->isInitialized = YES;
  }
  if (!recorder->fileHandle)
    return;
  @synchronized(recorder->fileHandle) {
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
      UInt32 len = ioData->mBuffers[i].mDataByteSize;
      if (len > 0 && ioData->mBuffers[i].mData) {
        [recorder->fileHandle
            writeData:[NSData dataWithBytesNoCopy:ioData->mBuffers[i].mData
                                           length:len
                                     freeWhenDone:NO]];
        recorder->totalDataBytes += len;
      }
    }
    if (recorder->totalDataBytes - recorder->lastCommittedBytes >
        FIX_HEADER_PERIOD_BYTES)
      updateWavHeader(recorder);
  }
}

static void finalizeRecorders(void) {
  if (micRecorder.fileHandle) {
    updateWavHeader(&micRecorder);
    [micRecorder.fileHandle closeFile];
    micRecorder = (WavRecorder){0};
  }
  if (speakerRecorder.fileHandle) {
    updateWavHeader(&speakerRecorder);
    [speakerRecorder.fileHandle closeFile];
    speakerRecorder = (WavRecorder){0};
  }
}

// --- Audio Hooks ---

// Speaker: post-render notify fires on the I/O unit's hardware output cycle
// (bus 0). This fires regardless of how WhatsApp's VoIP stack registers its
// render callback — unlike kAudioUnitProperty_SetRenderCallback interception,
// which only works if WhatsApp calls AudioUnitSetProperty from our-hooked code
// path.
static OSStatus speakerRenderNotify(void *inRefCon,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inBusNumber, UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
  if ((*ioActionFlags & kAudioUnitRenderAction_PostRender) &&
      inBusNumber == 0 && ioData)
    appendAudio(&speakerRecorder, ioData, @"speaker");
  return noErr;
}

// Mic: bus 1 of AudioUnitRender is the hardware microphone input.
static OSStatus
hooked_AudioUnitRender(AudioUnit inUnit,
                       AudioUnitRenderActionFlags *ioActionFlags,
                       const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                       UInt32 inNumberFrames, AudioBufferList *ioData) {
  OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp,
                                         inBusNumber, inNumberFrames, ioData);
  if (status == noErr && inBusNumber == 1 && ioData)
    appendAudio(&micRecorder, ioData, @"mic");
  return status;
}

// ASBD capture only — render callback interception removed (caused pink noise
// when WhatsApp's VoIP stack set multiple render callbacks across audio units).
static OSStatus
hooked_AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID,
                            AudioUnitScope inScope, AudioUnitElement inElement,
                            const void *inData, UInt32 inDataSize) {
  if (inID == kAudioUnitProperty_StreamFormat && inData &&
      inDataSize >= sizeof(AudioStreamBasicDescription)) {
    capturedASBD = *(AudioStreamBasicDescription *)inData;
    debug_print(@"[CallRecordWav] ASBD: %.0f Hz, %d ch",
                capturedASBD.mSampleRate, capturedASBD.mChannelsPerFrame);
  }
  return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData,
                                   inDataSize);
}

// Install render notify for speaker capture when the I/O unit starts.
static OSStatus hooked_AudioOutputUnitStart(AudioUnit unit) {
  OSStatus err = AudioUnitAddRenderNotify(unit, speakerRenderNotify, NULL);
  debug_print(@"[CallRecordWav] Render notify on I/O unit: %s (err=%d)",
              err == noErr ? "ok" : "FAILED", (int)err);
  return orig_AudioOutputUnitStart(unit);
}

// --- WACallManager hooks ---

static IMP hook_method(Class cls, SEL sel, IMP newIMP) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m)
    return NULL;
  IMP orig = method_getImplementation(m);
  if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m)))
    method_setImplementation(class_getInstanceMethod(cls, sel), newIMP);
  return orig;
}

static NSString *userFromJID(id jid) {
  if (!jid)
    return nil;
  NSString *s = [NSString stringWithFormat:@"%@", jid];
  if ([s hasPrefix:@"<"] && [s hasSuffix:@">"]) {
    s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
  }
  NSRange at = [s rangeOfString:@"@"];
  if (at.location != NSNotFound)
    s = [s substringToIndex:at.location];
  s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return s.length > 0 ? s : nil;
}

static void hookWACallManagerForRecording(void) {
  Class cls = NSClassFromString(@"WACallManager");
  if (!cls)
    return;

  // Outgoing: capture phone JID before audio starts
  {
    SEL sel = @selector
        (attemptOutgoingCallTo:
                   withChatJID:callUISource:withVideo:from:accountService
                              :chatStorage:createdWithoutContactBookAccess
                              :startCallTimestamp:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(
          id self, id peerJIDs, id chatJID, NSInteger src, BOOL video, id from,
          id acct, id storage, BOOL noBook, id ts) {
        NSString *user = userFromJID(chatJID);
        if (user)
          g_callInfo.peerID = user;
        debug_print(@"[CallRecordWav] OUTGOING → peer=%@", g_callInfo.peerID);
        ((void (*)(id, SEL, id, id, NSInteger, BOOL, id, id, id, BOOL,
                   id))orig)(self, sel, peerJIDs, chatJID, src, video, from,
                             acct, storage, noBook, ts);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Incoming: phoneUserCallerJID is the phone-number JID; callerJID is the @lid
  // one
  {
    SEL sel = @selector(
        reportIncomingCallFromCallerJID:
                        participantJIDs:phoneUserCallerJID
                                       :phoneUserParticipantJIDs:usernameMapping
                                       :totalGroupParticipantCount:callID
                                       :groupJID:isVideo:isGroupCall
                                       :isCallLinkCall:isCAPICall
                                       :isParticipantCoexUser:forceToReport
                                       :isVoiceChat:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(
          id self, id callerJID, id participantJIDs, id phoneCallerJID,
          id phoneParticipantJIDs, id usernameMapping, NSInteger totalCount,
          id callID, id groupJID, BOOL isVideo, BOOL isGroupCall,
          BOOL isCallLinkCall, BOOL isCAPICall, BOOL isCoexUser,
          BOOL forceReport, BOOL isVoiceChat) {
        NSString *user = userFromJID(phoneCallerJID) ?: userFromJID(callerJID);
        if (user)
          g_callInfo.peerID = user;
        debug_print(@"[CallRecordWav] INCOMING → peer=%@", g_callInfo.peerID);
        ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id, id, BOOL, BOOL,
                   BOOL, BOOL, BOOL, BOOL, BOOL))orig)(
            self, sel, callerJID, participantJIDs, phoneCallerJID,
            phoneParticipantJIDs, usernameMapping, totalCount, callID, groupJID,
            isVideo, isGroupCall, isCallLinkCall, isCAPICall, isCoexUser,
            forceReport, isVoiceChat);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Connected: stamp timestamp and activate recording
  {
    SEL sel = @selector(setCallConnected:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(^(id self, BOOL connected) {
        if (connected) {
          if (!g_callInfo.peerID)
            g_callInfo.peerID =
                userFromJID([self valueForKey:@"peerJid"]) ?: @"unknown";
          NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
          [fmt setDateFormat:@"yyyyMMddHHmmss"];
          g_callInfo.timestamp = [fmt stringFromDate:[NSDate date]];
          g_callInfo.isActive = YES;
          debug_print(@"[CallRecordWav] Connected → %@/%@_*.wav",
                      g_callInfo.peerID, g_callInfo.timestamp);
        }
        ((void (*)(id, SEL, BOOL))orig)(self, sel, connected);
      });
      hook_method(cls, sel, newIMP);
    }
  }

  // Ending: finalize WAV files
  {
    SEL sel = @selector
        (voipBridgeCallIsEndingWithCallEvent:
                          showRatingInterval:callID:voipTimeSeriesSubDir
                                            :callResult:isGroupCall:isBotCall:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
      IMP orig = method_getImplementation(m);
      IMP newIMP = imp_implementationWithBlock(
          ^(id self, id callEvent, double ratingInterval, NSString *callID,
            id subDir, NSInteger callResult, BOOL isGroupCall, BOOL isBotCall) {
            debug_print(@"[CallRecordWav] Ending, finalizing WAV files");
            finalizeRecorders();
            g_callInfo = (CallInfo){0};
            ((void (*)(id, SEL, id, double, NSString *, id, NSInteger, BOOL,
                       BOOL))orig)(self, sel, callEvent, ratingInterval, callID,
                                   subDir, callResult, isGroupCall, isBotCall);
          });
      hook_method(cls, sel, newIMP);
    }
  }
}

static void init() {
  hookWACallManagerForRecording();
  rebind_symbols(
      (struct rebinding[3]){
          {"AudioUnitRender", (void *)hooked_AudioUnitRender,
           (void **)&orig_AudioUnitRender},
          {"AudioUnitSetProperty", (void *)hooked_AudioUnitSetProperty,
           (void **)&orig_AudioUnitSetProperty},
          {"AudioOutputUnitStart", (void *)hooked_AudioOutputUnitStart,
           (void **)&orig_AudioOutputUnitStart}},
      3);
}

INITIALIZE("CallRecordWav")
