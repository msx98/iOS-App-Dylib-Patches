# CLAUDE.md

## Project Overview

iOS dylib tweak framework targeting apps running inside **LiveContainer**. Tweaks are written in Objective-C, compiled to ARM64 dylibs, signed, and deployed to an iPhone over a local network TCP socket.

## Repository Structure

```
tweaks/         Tweak source files (.m) organized by app
  whatsapp/     MicSpoof, CameraSpoof, CallRecord, WaLogger, etc.
  grindr/       Ad blockers (AppLovin, BidMachine, Vungle, etc.)
  telegram/     SpoofCloudKit, Telegram patches
lib/
  fishhook/     Facebook's PLT hooking library (submodule)
  LiveContainer/ LiveContainer framework headers (submodule)
  utils/        Shared headers: utils.h, foundation.h, logger.m
scripts/
  compile.sh                     Main compiler script
  compile_network_dylib_loader.sh Compile NetworkLoader/DylibLoaderNew
  serve                          Sign + deploy dylib to iPhone
  bridge.py                      Single-dylib TCP transfer server
  bridgenew.py                   Multi-dylib TCP transfer server
build/          Compiled dylib output directory (gitignored)
```

## Build Commands

**Compile a tweak:**
```bash
./scripts/compile.sh tweaks/<app>/<TweakName>
# e.g.
./scripts/compile.sh tweaks/whatsapp/MicSpoof
./scripts/compile.sh tweaks/grindr/GrindrAds
```

Output lands in `build/<TweakName>.dylib`.

**Compile the network dylib loader (links LiveContainer/ZSign):**
```bash
./scripts/compile_network_dylib_loader.sh
```

**Sign and deploy to iPhone:**
```bash
./scripts/serve tweaks/<app>/<TweakName>
```
This compiles, signs with the SideStore certificate in the local keychain, then calls `bridge.py` to push the dylib to the iPhone at `192.168.1.23:8887`.

**Convert call-recording binaries to WAV:**
```bash
./scripts/CallRecordingBinToWav.sh
```

## Compilation Details

- Target: `arm64-apple-ios26.3`
- SDK: `$(xcrun --sdk iphoneos --show-sdk-path)`
- Always linked: `fishhook`, `lib/utils/logger.m`, Foundation, UIKit, CoreAudio, AVFoundation, CoreMedia, CoreVideo, AudioToolbox
- Flags: `-fobjc-arc`, `-shared`, `-fmodules`
- Customize via env vars: `EXTRA_INCLUDES`, `EXTRA_SOURCES`, `EXTRA_FRAMEWORKS`

## Runtime / Deployment Architecture

1. **On Mac**: run `./scripts/serve` → compiles, signs, starts `bridge.py` TCP server on port 8887
2. **On iPhone (inside LiveContainer)**: `NetworkLoader.dylib` is injected as a tweak; its constructor connects back to the Mac, receives dylibs, writes them to `Documents/Tweaks/`, signs them via ZSign (NetworkLoader only), then calls `dlopen()`
3. **Logging**: UDP log packets sent from iPhone to Mac on port 8889; received by a listener on the Mac

## Key Patterns

- **Function hooking**: Use `fishhook` (`rebind_symbols`) for C/system functions (e.g. `AudioUnitRender`, `openURL`)
- **Method swizzling**: Use Objective-C runtime (`method_exchangeImplementations`) for ObjC methods
- **Dynamic symbol resolution**: Use `dlsym()` + `dlopen()` to call LiveContainer symbols at runtime without linking
- **Shared utilities**: Include `lib/utils/utils.m` to get `foundation.h` and `logger.m` network logging

## Certificates and Signing (gitignored)

The `serve` script expects:
- A `.p12` certificate file (SideStore signing cert)
- A temporary keychain created at build time
- `codesign` for signing the dylib before transfer

## Submodules

```bash
git submodule update --init --recursive
```

Required before building. Pulls in `lib/fishhook` and `lib/LiveContainer`.

## Target Devices

- iPhone at `192.168.1.23` (hardcoded in loader source files and scripts — update as needed)
- iOS 16+ / ARM64
