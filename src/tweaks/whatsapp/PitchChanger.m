#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>

#import "submodules/fishhook/fishhook.h"
#import "utils.h"

// Pitch drift — range and momentum tuning.
// ±800 cents = roughly ±8 semitones; speech stays recognisable within this range.
static const float kPitchMin     = +200.0f;
static const float kPitchMax     = +800.0f;
static const float kPitchDamp    =    0.90f;  // stronger damp than overlap for smoother glide
static const float kPitchImpulse =   25.0f;   // cents per update; scales momentum buildup

// Overlap drift — range and momentum tuning.
// Overlap affects phase-vocoder quality; 4–16 keeps speech intelligible.
static const float kOverlapMin  =  4.0f;
static const float kOverlapMax  = 32.0f;
// Damping per update (0 = instant stop, 1 = no damping).
static const float kOverlapDamp =  0.92f;
// Max random impulse magnitude added to momentum each update.
static const float kOverlapImpulse = 2.00f;
// Update overlap every N render calls (~200 ms at typical 10 ms buffers).
static const int   kOverlapUpdateEvery = 1;

// --- Globals ---
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                        const AudioTimeStamp *, UInt32, UInt32,
                                        AudioBufferList *);

static AVAudioEngine *g_engine = nil;
static AVAudioUnitTimePitch *g_pitchNode = nil;
static AVAudioSourceNode *g_sourceNode = nil;
static AVAudioFormat *g_format = nil;
static AVAudioEngineManualRenderingBlock g_renderBlock = nil;
static BOOL g_engineReady = NO;

// Overlap drift state.
static float g_overlap         = 8.0f;
static float g_overlapMomentum = 0.0f;

// Pitch drift state — starts at centre of range (0 = no shift).
static float g_pitch           = 410.0f;
static float g_pitchMomentum   = 30.0f;

// Shared tick counter drives both overlap and pitch updates.
static int   g_overlapTick     = 0;

// The AudioUnit the engine was set up for. If a different unit is seen
// (e.g. VoiceProcessingIO for calls vs RemoteIO for voice notes), we
// tear down and rebuild so the format is detected fresh.
static AudioUnit g_lastUnit = NULL;

// Whether the mic buffer is float32 (YES) or int16 (NO).
static BOOL g_micIsFloat = NO;

// Scratch buffer holding mic data converted to float32 for the source node.
// Sized to the largest frameCount seen.
static float *g_floatMicBuf = NULL;
static UInt32 g_floatMicBufCapacity = 0;

// Shared between hooked_AudioUnitRender and the source node render callback.
// Points into g_floatMicBuf and is only valid during g_renderBlock().
static const float *g_currentMicData = NULL;
static UInt32 g_currentFrameCount = 0;

// Called every kOverlapUpdateEvery render calls.
// Applies a random impulse to momentum, damps, moves overlap, bounces at bounds.
static void updateOverlap(void) {
    // Random impulse in [-kOverlapImpulse, +kOverlapImpulse]
    float r = (float)(arc4random() % 10000) / 10000.0f;  // [0, 1)
    float impulse = (r - 0.5f) * 2.0f * kOverlapImpulse;
    g_overlapMomentum = g_overlapMomentum * kOverlapDamp + impulse;
    g_overlap += g_overlapMomentum;
    // Bounce off bounds rather than hard-clamping, so momentum reverses.
    if (g_overlap < kOverlapMin) { g_overlap = kOverlapMin; g_overlapMomentum = fabsf(g_overlapMomentum) * 0.5f; }
    if (g_overlap > kOverlapMax) { g_overlap = kOverlapMax; g_overlapMomentum = -fabsf(g_overlapMomentum) * 0.5f; }
    g_pitchNode.overlap = g_overlap;
}

static void updatePitch(void) {
    float r = (float)(arc4random() % 10000) / 10000.0f;
    float impulse = (r - 0.5f) * 2.0f * kPitchImpulse;
    g_pitchMomentum = g_pitchMomentum * kPitchDamp + impulse;
    g_pitch += g_pitchMomentum;
    if (g_pitch < kPitchMin) { g_pitch = kPitchMin; g_pitchMomentum =  fabsf(g_pitchMomentum) * 0.5f; }
    if (g_pitch > kPitchMax) { g_pitch = kPitchMax; g_pitchMomentum = -fabsf(g_pitchMomentum) * 0.5f; }
    g_pitchNode.pitch = g_pitch;
}

static void setupEngine(double sampleRate, UInt32 channels) {
    g_engine = [[AVAudioEngine alloc] init];
    g_pitchNode = [[AVAudioUnitTimePitch alloc] init];
    g_pitchNode.pitch = g_pitch;
    // overlap = 8 gives natural-sounding pitch shift. Safe now that AVAudioSourceNode
    // feeds data synchronously — no scheduling race to cause InsufficientDataFromInputNode.
    g_pitchNode.overlap = 8.0f;

    g_format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:sampleRate
                                                 channels:channels
                                              interleaved:NO];

    // AVAudioSourceNode feeds float32 mic data synchronously during g_renderBlock.
    g_sourceNode = [[AVAudioSourceNode alloc] initWithFormat:g_format
                                                 renderBlock:^OSStatus(BOOL *isSilence,
                                                                       const AudioTimeStamp *ts,
                                                                       AVAudioFrameCount frameCount,
                                                                       AudioBufferList *outputData) {
        if (g_currentMicData && g_currentFrameCount == frameCount) {
            memcpy(outputData->mBuffers[0].mData, g_currentMicData,
                   frameCount * sizeof(float));
        } else {
            *isSilence = YES;
        }
        return noErr;
    }];

    [g_engine attachNode:g_sourceNode];
    [g_engine attachNode:g_pitchNode];

    [g_engine connect:g_sourceNode to:g_pitchNode format:g_format];
    [g_engine connect:g_pitchNode to:g_engine.mainMixerNode format:g_format];

    NSError *err;
    BOOL ok = [g_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeRealtime
                                           format:g_format
                                 maximumFrameCount:4096
                                            error:&err];
    if (!ok) {
        debug_print(@"[PitchChanger] enableManualRenderingMode failed: %@", err);
        return;
    }

    ok = [g_engine startAndReturnError:&err];
    if (!ok) {
        debug_print(@"[PitchChanger] engine start failed: %@", err);
        return;
    }

    g_renderBlock = g_engine.manualRenderingBlock;
    g_engineReady = YES;

    debug_print(@"[PitchChanger] Engine ready — sr=%.0f ch=%u pitch=%.0f cents micFloat=%d",
                sampleRate, (unsigned)channels, g_pitch, (int)g_micIsFloat);
}

// Detect the actual stream format from the AudioUnit on first call.
static void detectAndSetup(AudioUnit inUnit) {
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    OSStatus err = AudioUnitGetProperty(inUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Output, 1,
                                        &asbd, &size);
    double sr = (err == noErr && asbd.mSampleRate > 0) ? asbd.mSampleRate : 24000.0;
    UInt32 ch = (err == noErr && asbd.mChannelsPerFrame > 0) ? asbd.mChannelsPerFrame : 1;
    g_micIsFloat = (err == noErr) && (asbd.mFormatFlags & kAudioFormatFlagIsFloat);
    debug_print(@"[PitchChanger] Mic ASBD: sr=%.0f ch=%u bps=%u flags=0x%x isFloat=%d",
                sr, (unsigned)ch, (unsigned)asbd.mBitsPerChannel,
                (unsigned)asbd.mFormatFlags, (int)g_micIsFloat);
    setupEngine(sr, ch);
}

// --- HOOK: AudioUnitRender ---
OSStatus hooked_AudioUnitRender(AudioUnit inUnit,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber, UInt32 inNumberFrames,
                                AudioBufferList *ioData) {
    // Let the original run first — it fills ioData with actual mic audio.
    OSStatus status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp,
                                           inBusNumber, inNumberFrames, ioData);
    if (status != noErr) return status;

    do {
      if (inBusNumber != 1 || ioData == NULL) break;
      if (ioData->mNumberBuffers == 0 || ioData->mBuffers[0].mData == NULL) break;

      if (!g_engineReady || inUnit != g_lastUnit) {
          // Tear down existing engine so format is re-detected for this unit.
          if (g_engine) {
              [g_engine stop];
              g_engine = nil;
              g_pitchNode = nil;
              g_sourceNode = nil;
              g_renderBlock = nil;
              g_engineReady = NO;
              g_overlap = 8.0f;
              g_overlapMomentum = 0.0f;
              g_pitch = 0.0f;
              g_pitchMomentum = 0.0f;
              g_overlapTick = 0;
          }
          g_lastUnit = inUnit;
          detectAndSetup(inUnit);
      }
      if (!g_engineReady) break;

      // Use inNumberFrames — byteSize/sizeof(float) is wrong for Int16 buffers.
      UInt32 frameCount = inNumberFrames;
      if (frameCount == 0 || frameCount > 4096) break;

      // Grow scratch float buffer if needed.
      if (frameCount > g_floatMicBufCapacity) {
          free(g_floatMicBuf);
          g_floatMicBuf = (float *)malloc(frameCount * sizeof(float));
          g_floatMicBufCapacity = frameCount;
      }

      // Convert mic data to float32 for the pitch node.
      
      if (g_micIsFloat) {
          memcpy(g_floatMicBuf, ioData->mBuffers[0].mData, frameCount * sizeof(float));
      } else {
          // Int16 → Float32, normalised to [-1, 1]
          int16_t *src = (int16_t *)ioData->mBuffers[0].mData;
          vDSP_vflt16(src, 1, g_floatMicBuf, 1, frameCount);
          float scale = 1.0f / 32768.0f;
          vDSP_vsmul(g_floatMicBuf, 1, &scale, g_floatMicBuf, 1, frameCount);
      }

      g_currentMicData = g_floatMicBuf;
      g_currentFrameCount = frameCount;

      // Drift pitch and overlap on a slow timer so they wander without jitter.
      if (++g_overlapTick >= kOverlapUpdateEvery) {
          g_overlapTick = 0;
          updatePitch();
          updateOverlap();
      }

      AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:g_format
                                                              frameCapacity:frameCount];
      outBuf.frameLength = frameCount;
      OSStatus renderErr;
      AVAudioEngineManualRenderingStatus rs = g_renderBlock(frameCount,
                                                            (AudioBufferList *)outBuf.audioBufferList,
                                                            &renderErr);
      g_currentMicData = NULL;
      g_currentFrameCount = 0;

      if (rs == AVAudioEngineManualRenderingStatusSuccess && outBuf.frameLength > 0) {
          float *out = outBuf.floatChannelData[0];
          float peak = 0.0f;
          vDSP_maxmgv(out, 1, &peak, outBuf.frameLength);
          if (peak > 1e-6f) {
              if (g_micIsFloat) {
                  memcpy(ioData->mBuffers[0].mData, out, outBuf.frameLength * sizeof(float));
              } else {
                  // Clip to [-1, 1] first — phase vocoder can exceed 1.0, and
                  // vDSP_vfix16 has undefined behaviour outside Int16 range.
                  float clipLo = -1.0f, clipHi = 1.0f;
                  vDSP_vclip(out, 1, &clipLo, &clipHi, g_floatMicBuf, 1, outBuf.frameLength);
                  float scale = 32768.0f;
                  vDSP_vsmul(g_floatMicBuf, 1, &scale, g_floatMicBuf, 1, outBuf.frameLength);
                  vDSP_vfix16(g_floatMicBuf, 1, (int16_t *)ioData->mBuffers[0].mData, 1, outBuf.frameLength);
              }
          }
          debug_print(@"[PitchChanger] render ok frames=%u peak=%.5f, OL=%.0f, p=%.0f", outBuf.frameLength, peak, g_overlap, g_pitch);
      } else {
          debug_print(@"[PitchChanger] render status=%d err=%d frames=%u", (int)rs, (int)renderErr, frameCount);
      }
    } while (0);

    return status;
}

void init() {
    orig_AudioUnitRender = dlsym(RTLD_NEXT, "AudioUnitRender");
    rebind_symbols(
        (struct rebinding[1]){{"AudioUnitRender", hooked_AudioUnitRender,
                               (void *)&orig_AudioUnitRender}},
        1);
    debug_print(@"[PitchChanger] Hooked AudioUnitRender — pitch drifting [%.0f, %.0f] cents", kPitchMin, kPitchMax);
}


