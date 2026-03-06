cmake_minimum_required(VERSION 3.21)

# ── iOS cross-compilation (must be set before project()) ─────────────────────
execute_process(
    COMMAND xcrun --sdk iphoneos --show-sdk-path
    OUTPUT_VARIABLE CMAKE_OSX_SYSROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0")

project(iOS-App-Dylib-Patches OBJC OBJCXX C)

# ── clangd / IDE support ─────────────────────────────────────────────────────
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── Output directory ─────────────────────────────────────────────────────────
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY         ${CMAKE_SOURCE_DIR}/build)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_DEBUG   ${CMAKE_SOURCE_DIR}/build)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE ${CMAKE_SOURCE_DIR}/build)

# ── Common compile flags ─────────────────────────────────────────────────────
add_compile_options(-fobjc-arc)

# ── Common frameworks (always linked) ────────────────────────────────────────
set(COMMON_FRAMEWORKS
    "-framework CoreAudio"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework AudioToolbox"
    "-framework UIKit"
    "-framework Foundation"
)

# ── fishhook (compiled once, shared via OBJECT library) ──────────────────────
add_library(fishhook OBJECT src/submodules/fishhook/fishhook.c)
target_include_directories(fishhook PUBLIC src/submodules/fishhook)

# ── Dobby ─────────────────────────────────────────────────────────────────────
set(DOBBY_BUILD_EXAMPLE  OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST     OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_SILICON  ON  CACHE BOOL "" FORCE)
add_subdirectory(src/submodules/Dobby EXCLUDE_FROM_ALL)

# ── Helper function ───────────────────────────────────────────────────────────
# add_tweak(<name> <source>
#            [FRAMEWORKS f1 f2 ...]       extra -framework flags
#            [LINKS l1 l2 ...]            extra -l flags
#            [EXTRA_LINK_FLAGS flag ...])  verbatim extra link flags (e.g. .a paths)
function(add_tweak name source)
    cmake_parse_arguments(ARG "" "" "FRAMEWORKS;LINKS;EXTRA_LINK_FLAGS" ${ARGN})

    add_library(${name} SHARED ${source} $<TARGET_OBJECTS:fishhook>)

    set_target_properties(${name} PROPERTIES
        PREFIX ""
        SUFFIX ".dylib"
        OUTPUT_NAME ${name}
    )

    target_include_directories(${name}
        PRIVATE src
    )

    target_link_libraries(${name} PRIVATE ${COMMON_FRAMEWORKS})

    foreach(fw IN LISTS ARG_FRAMEWORKS)
        target_link_libraries(${name} PRIVATE "-framework ${fw}")
    endforeach()

    foreach(lib IN LISTS ARG_LINKS)
        target_link_libraries(${name} PRIVATE "-l${lib}")
    endforeach()

    if(ARG_EXTRA_LINK_FLAGS)
        target_link_options(${name} PRIVATE ${ARG_EXTRA_LINK_FLAGS})
    endif()
endfunction()

# ═════════════════════════════════════════════════════════════════════════════
# Tweaks
# ═════════════════════════════════════════════════════════════════════════════

# ── Core ──────────────────────────────────────────────────────────────────────
add_tweak(NetworkLoader  src/tweaks/NetworkLoader.m  LINKS sqlite3)
add_tweak(FlexDispatcher src/tweaks/FlexDispatcher.m)
add_tweak(VTableExplorer src/tweaks/VTableExplorer.m)

# ── WhatsApp ─────────────────────────────────────────────────────────────────
add_tweak(MicSpoof      src/tweaks/whatsapp/MicSpoof.m)
add_tweak(CameraSpoof   src/tweaks/whatsapp/CameraSpoof.m
          FRAMEWORKS CoreGraphics QuartzCore ImageIO CoreImage)
add_tweak(PitchChanger  src/tweaks/whatsapp/PitchChanger.m
          FRAMEWORKS Accelerate)
add_tweak(CallRecord       src/tweaks/whatsapp/CallRecord.m)
add_tweak(CallRecordWav    src/tweaks/whatsapp/CallRecordWav.m)
add_tweak(CallRecordExp    src/tweaks/whatsapp/CallRecordExp.m)
add_tweak(CallRecordWavExp src/tweaks/whatsapp/CallRecordWavExp.m)
add_tweak(CallDebug_File   src/tweaks/whatsapp/CallDebug_File.m)
add_tweak(CallDebugPlus    src/tweaks/whatsapp/CallDebugPlus.m)
add_tweak(WaLogger                       src/tweaks/whatsapp/WaLogger.m)
add_tweak(WhatsAppBypassSecureEntry      src/tweaks/whatsapp/BypassSecureEntry.m)
add_tweak(WhatsAppDisableSiriEntitlement src/tweaks/whatsapp/WhatsAppDisableSiriEntitlement.m)

# ── Telegram ─────────────────────────────────────────────────────────────────
add_tweak(Telegram          src/tweaks/telegram/Telegram.m
          FRAMEWORKS UserNotifications)
add_tweak(SpoofCloudKit     src/tweaks/telegram/SpoofCloudKit.m
          FRAMEWORKS CloudKit)
add_tweak(FindCopyProtected src/tweaks/telegram/FindCopyProtected.m
          LINKS c++)
target_link_libraries(FindCopyProtected PRIVATE dobby)
add_tweak(TelegramBypassSecureEntry src/tweaks/telegram/BypassSecureEntry.m)
add_tweak(RemoveObserver            src/tweaks/telegram/RemoveObserver.m)
add_tweak(DisableSiriINPreferences  src/tweaks/telegram/DisableSiriINPreferences.m)

# ── WeChat ────────────────────────────────────────────────────────────────────
add_tweak(WebRecorder src/tweaks/wechat/WebRecorder.m
          FRAMEWORKS ScreenTime)

# ── Grindr ────────────────────────────────────────────────────────────────────
add_tweak(AppLovin           src/tweaks/grindr/AppLovin.m
          FRAMEWORKS UserNotifications)
add_tweak(AppLovinMax        src/tweaks/grindr/AppLovinMax.m)
add_tweak(BidMachine         src/tweaks/grindr/BidMachine.m)
add_tweak(GrindrAds          src/tweaks/grindr/GrindrAds.m)
add_tweak(SafariPopupBlocker src/tweaks/grindr/SafariPopupBlocker.m)
add_tweak(Unity              src/tweaks/grindr/Unity.m)
add_tweak(Vungle             src/tweaks/grindr/Vungle.m)

# ── General ───────────────────────────────────────────────────────────────────
add_tweak(Contacts src/tweaks/general/Contacts.m
          FRAMEWORKS Contacts)

# ── UI ────────────────────────────────────────────────────────────────────────
add_tweak(DisableScreenCaptureDetection src/tweaks/UI/DisableScreenCaptureDetection.m)
