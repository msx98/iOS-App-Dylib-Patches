# CLAUDE.md

## Project Overview

iOS tweak framework targeting apps running inside **LiveContainer**. Tweaks are written in Objective-C (`.m`) or Objective-C++ (`.mm`), compiled to ARM64 dylibs, and deployed to an iPhone over a local network TCP socket.

## Repository Structure

```
src/                  Source files
  utils.m             Includes debug_print, INITIALIZE, etc
  tweaks/             Tweak source files organized by app
    whatsapp/         MicSpoof, CameraSpoof, CallRecord*, WaLogger, PitchChanger, BypassSecureEntry, etc.
    telegram/         SpoofCloudKit, FindCopyProtected, BypassSecureEntry, RemoveObserver, etc.
    grindr/           Ad blockers (AppLovin, BidMachine, Vungle, Unity, etc.)
    wechat/           WebRecorder
    general/          Contacts (spoof contacts)
    UI/               DisableScreenCaptureDetection
    NetworkLoader.m   Dylib loader injected into LiveContainer apps
    VTableExplorer.m  Runtime vtable inspection tool
    FlexDispatcher.m  Runtime method dispatcher
  submodules/
    fishhook/         Facebook's PLT hooking library (submodule)
    LiveContainer/    LiveContainer framework headers (submodule)
    Dobby/            Inline hook library (submodule)
scripts/
  compile       Main compiler script (bash)
  serve         Compile-on-demand + TCP server (Python) — deploys to iPhone
build/          Compiled dylib output directory (gitignored)
```

## Build Commands

**Compile a tweak:**
```bash
./scripts/compile src/tweaks/<app>/<TweakName>.m
# e.g.
./scripts/compile src/tweaks/whatsapp/MicSpoof.m
```

Supports `.m` (clang) and `.mm` (clang++) files. Multiple files can be passed at once. Output lands in `build/<TweakName>.dylib`.

**Sign and deploy to iPhone:**
```bash
./scripts/serve src/tweaks/<app>/<TweakName>.m [src/tweaks/<app>/<Other>.m ...]
```

This Python server:
1. Compiles each `.m`/`.mm` if source is newer than the cached dylib
2. Sends a manifest (name + SHA256 + mtime) to the iPhone
3. Transfers only the dylibs the iPhone reports as missing or stale
4. Always prepends `NetworkLoader.m` as the first dylib
5. Listens for UDP log packets from the iPhone on port 8889

## Compilation Details

- Target: `arm64-apple-ios26.3`
- SDK: `$(xcrun --sdk iphoneos --show-sdk-path)`
- Always linked: `fishhook` (`src/submodules/fishhook/fishhook.c`), Foundation, UIKit, CoreAudio, AVFoundation, CoreMedia, CoreVideo, AudioToolbox
- Flags: `-dynamiclib`, `-fobjc-arc`
- `.m` → `clang`; `.mm` → `clang++` (C sources compiled with `-x c`)
- `src/` added via `-I` (user includes)
- Per-tweak `.env` file: place `<TweakName>.env` next to the source to override any `CLANG_*` var
- Customize via env vars: `CLANG_EXTRA_INCLUDES`, `CLANG_EXTRA_SYSTEM_INCLUDES`, `CLANG_EXTRA_SOURCES`, `CLANG_EXTRA_FRAMEWORKS`, `CLANG_EXTRA_LINKS`, `EXTRA_FLAGS`

## Runtime / Deployment Architecture

1. **On Mac**: run `./scripts/serve src/...` → compiles as needed, starts TCP server on port 8887
2. **On iPhone (inside LiveContainer)**: `NetworkLoader.dylib` is injected; its constructor connects to the Mac, receives new/changed dylibs, writes them to `Documents/Tweaks/`, then calls `dlopen()`
3. **Logging**: UDP log packets sent from iPhone to Mac on port 8889; printed to stdout by the serve script

## Key Patterns

- **Function hooking**: Use `fishhook` (`rebind_symbols`) for C/system functions (e.g. `AudioUnitRender`, `openURL`)
- **Method swizzling**: Use Objective-C runtime (`method_exchangeImplementations`) for ObjC methods
- **Dynamic symbol resolution**: Use `dlsym()` + `dlopen()` to call LiveContainer symbols at runtime without linking
- **Shared utilities**: Include `"utils.m"` (resolved via `-I src/`) to get network logging helpers

## Submodules

```bash
git submodule update --init --recursive
```

Required after cloning. Pulls in `src/submodules/fishhook`, `src/submodules/LiveContainer`, and `src/submodules/Dobby`.
