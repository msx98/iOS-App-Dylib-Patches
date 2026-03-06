# iOS-App-Dylib-Patches

Tweaks for iOS apps running inside [LiveContainer](https://github.com/LiveContainer/LiveContainer). Can be deployed over a local TCP socket without jailbreak.

## [Tweaks](/src/tweaks/) (`src/tweaks/`)

### General
- **DisableSiriINPreferences, WhatsAppDisableSiriEntitlement** - enables launching WhatsApp, Telegram and WeChat without a paid developer account (no Siri entitlement)
- **BypassSecureEntry** — enables screenshots in apps that don't allow them, including WhatsApp and Telegram
- **Contacts** — spoofs the device contact list authorization status to full (even when only a partial list is exposed to LiveContainer)
- **FlexDispatcher** — launches Flex (a GUI debugger) automatically after app launch (requires injecting Flex)

### WhatsApp
- **CallRecordWav** — records call audio
- **PitchChanger** — shifts microphone pitch during calls
- **MicSpoof** — replaces microphone audio with a custom audio source
- **CameraSpoof** — replaces camera feed with a custom source

### Telegram
- **SpoofCloudKit** — allows creating new accounts by mocking some CloudKit functionality
- **RemoveObserver** — removes problematic NSNotificationCenter observers

### WeChat
- **DisableSiriINPreferences** - required in order to launch without the Siri entitlement
- **WebRecorder** — hooks `STWebpageController` to log browsing activity (URLs)

### Grindr
- **GrindrAds** — combined ad blocker
- **AppLovin / AppLovinMax** — blocks AppLovin/MAX ad SDK
- **BidMachine** — blocks BidMachine ad SDK
- **Vungle** — blocks Vungle ad SDK
- **Unity** — blocks Unity ad SDK
- **SafariPopupBlocker** — blocks in-app Safari popups

### Utilities
- **NetworkLoader** — injected into LiveContainer apps; can be used to quickly "deploy" tweaks. Receives updated dylibs, and `dlopen()`s them at runtime
- **VTableExplorer** — runtime vtable inspection tool

## Setup

```bash
git submodule update --init --recursive
```

## Build & Deploy

**Compile:**
```bash
# Everything in CMakeLists.txt
cmake --build build-cmake
# Just TelegramBypassSecureEntry
cmake --build build-cmake --target TelegramBypassSecureEntry
# Your own file
./scripts/compile /path/to/file1.m /path/to/file2.mm
```

**Compile and deploy to iPhone:**
```bash
./scripts/serve /path/to/lib.dylib /path/to/file1.m /path/to/file2.mm
```

The `serve` script compiles, then starts a TCP server on port 8887. On the iPhone, `NetworkLoader` connects back and loads the dylib. Logs stream back over UDP on port 8889.
