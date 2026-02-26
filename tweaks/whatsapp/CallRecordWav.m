#import "fishhook.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdint.h>

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
static AudioStreamBasicDescription micASBD;
static AudioStreamBasicDescription speakerASBD;
static BOOL micASBDCaptured;
static BOOL speakerASBDCaptured;
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

static void writeInitialHeader(NSFileHandle *handle,
                               AudioStreamBasicDescription *asbd) {
  WavHeader h;
  memcpy(h.riff, "RIFF", 4);
  memcpy(h.wave, "WAVE", 4);
  memcpy(h.fmt, "fmt ", 4);
  h.fmtLen = 16;
  BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  h.format = isFloat ? 3 : 1; // 3=IEEE float, 1=PCM int
  h.sampleRate = asbd->mSampleRate > 0 ? (uint32_t)asbd->mSampleRate : 48000;
  h.channels = asbd->mChannelsPerFrame > 0 ? (uint16_t)asbd->mChannelsPerFrame : 1;
  h.bitsPerSample = asbd->mBitsPerChannel > 0 ? (uint16_t)asbd->mBitsPerChannel : 32;
  h.byteRate = h.sampleRate * h.channels * (h.bitsPerSample / 8);
  h.blockAlign = h.channels * (h.bitsPerSample / 8);
  memcpy(h.data, "data", 4);
  h.fileSize = 0;
  h.dataLen = 0;
  [handle writeData:[NSData dataWithBytes:&h length:sizeof(WavHeader)]];
}

static NSFileHandle *createCaptureFile(NSString *suffix,
                                       AudioStreamBasicDescription *asbd) {
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
    writeInitialHeader(handle, asbd);
    debug_print(@"[CallRecordWav] Recording → %@", path);
  }
  return handle;
}

static void appendAudio(WavRecorder *recorder, AudioBufferList *ioData,
                        NSString *suffix, AudioStreamBasicDescription *asbd) {
  if (!g_callInfo.isActive || !ioData)
    return;
  if (!recorder->isInitialized) {
    recorder->fileHandle = createCaptureFile(suffix, asbd);
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
  micASBDCaptured = NO;
  speakerASBDCaptured = NO;
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
    appendAudio(&speakerRecorder, ioData, @"speaker", &speakerASBD);
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
  if (status == noErr && inBusNumber == 1 && ioData) {
    // Query live format once so the WAV header reflects the actual data format.
    if (!micASBDCaptured) {
      AudioStreamBasicDescription q = {0};
      UInt32 sz = sizeof(q);
      if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output, 1, &q, &sz) == noErr) {
        micASBD = q;
      }
      micASBDCaptured = YES;
      debug_print(
          @"[CallRecordWav] Mic live ASBD: %.0f Hz, %d ch, %d bpc, flags=0x%x",
          micASBD.mSampleRate, (int)micASBD.mChannelsPerFrame,
          (int)micASBD.mBitsPerChannel, (unsigned int)micASBD.mFormatFlags);
    }
    appendAudio(&micRecorder, ioData, @"mic", &micASBD);
  }
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
    AudioStreamBasicDescription asbd = *(AudioStreamBasicDescription *)inData;
    if (inElement == 1) {
      // Log what WhatsApp reports but keep mic hardcoded to 16kHz mono
      debug_print(
          @"[CallRecordWav] Mic ASBD (reported, ignored): %.0f Hz, %d ch",
          asbd.mSampleRate, (int)asbd.mChannelsPerFrame);
    } else {
      speakerASBD = asbd;
      debug_print(@"[CallRecordWav] Speaker ASBD: %.0f Hz, %d ch",
                  speakerASBD.mSampleRate, (int)speakerASBD.mChannelsPerFrame);
    }
  }
  return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData,
                                   inDataSize);
}

// Install render notify for speaker capture when the I/O unit starts.
static OSStatus hooked_AudioOutputUnitStart(AudioUnit unit) {
  // Query speaker format here — safe to call outside the audio render thread.
  if (!speakerASBDCaptured) {
    AudioStreamBasicDescription q = {0};
    UInt32 sz = sizeof(q);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 0, &q, &sz) == noErr &&
        q.mSampleRate > 0) {
      speakerASBD = q;
    }
    speakerASBDCaptured = YES;
    debug_print(@"[CallRecordWav] Speaker ASBD: %.0f Hz, %d ch, %d bpc, flags=0x%x",
                speakerASBD.mSampleRate, (int)speakerASBD.mChannelsPerFrame,
                (int)speakerASBD.mBitsPerChannel, (unsigned int)speakerASBD.mFormatFlags);
  }
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
