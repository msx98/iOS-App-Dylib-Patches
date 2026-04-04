#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#include <time.h>

#import "utils.h"
#import "submodules/fishhook/fishhook.h"

// ─── Spoofed coordinates + locale + timezone ─────────────────────────────────
// Loaded from <Documents>/location.txt ("lat,lon[,locale[,Timezone/Name]]"),
// e.g. "31.041,32.194,en-US,Asia/Jerusalem"
// Timezone is optional — omit to auto-detect from coordinates.

static CLLocationDegrees spoofLat = 32.084270;
static CLLocationDegrees spoofLon = 34.769603;
static NSString *spoofTimezoneID  = nil; // nil = no timezone spoofing
static NSString *spoofLocaleID    = nil; // nil = no locale spoofing
static NSString *spoofISOCountryCode = nil; // nil = no telephony country spoofing
static NSString *spoofMobileCountryCode = nil; // nil = no MCC spoofing
static NSString *spoofMobileNetworkCode = nil; // nil = no MNC spoofing
static NSString *spoofPhoneNumber       = nil; // nil = no phone number spoofing

static NSString *trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *normalizedISOCountryCode(NSString *countryCode) {
    NSString *t = trimmed(countryCode);
    if (!t.length) return nil;
    return t.lowercaseString;
}


static NSString *mobileCountryCodeForISO(NSString *isoCode) {
    static NSDictionary<NSString *, NSString *> *mccByISO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mccByISO = @{
            @"ae": @"424", @"at": @"232", @"au": @"505", @"br": @"724", @"ca": @"302",
            @"de": @"262", @"es": @"214", @"fr": @"208", @"gb": @"234",
            @"il": @"425", @"in": @"404", @"it": @"222", @"jp": @"440",
            @"kr": @"450", @"mx": @"334", @"nl": @"204", @"pl": @"260",
            @"ro": @"226", @"ru": @"250", @"sa": @"420", @"tr": @"286", @"ua": @"255",
            @"us": @"310"
        };
    });
    return mccByISO[isoCode];
}

static void applyISOCountryCode(NSString *isoCode) {
    NSString *normalized = normalizedISOCountryCode(isoCode);
    if (!normalized.length) return;
    spoofISOCountryCode = normalized;
    NSString *mcc = mobileCountryCodeForISO(normalized);
    if (mcc.length) {
        spoofMobileCountryCode = mcc;
    }
    if (!spoofMobileNetworkCode.length) {
        // Keep MCC/MNC pair structurally valid when apps parse both.
        spoofMobileNetworkCode = @"01";
    }
    debug_print(@"[LocationSpoof] Carrier ISO applied: %@ (mcc=%@, mnc=%@)",
                spoofISOCountryCode,
                spoofMobileCountryCode ?: @"(none)",
                spoofMobileNetworkCode ?: @"(none)");
}

static void loadPhoneNumber(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"phone.txt"];
    NSString *raw = trimmed([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]);
    if (raw.length) {
        spoofPhoneNumber = raw;
        debug_print(@"[LocationSpoof] Phone number loaded: %@", spoofPhoneNumber);
    }
}

static void loadCoordinates(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"location.txt"];
    NSString *raw = [trimmed([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]) copy];
    if (raw.length) {
        NSArray<NSString *> *parts = [raw componentsSeparatedByString:@","];
        if (parts.count >= 2) {
            CLLocationDegrees lat = [parts[0] doubleValue];
            CLLocationDegrees lon = [parts[1] doubleValue];
            if (lat != 0.0 || lon != 0.0) {
                spoofLat = lat;
                spoofLon = lon;
                if (parts.count >= 3) {
                    NSString *locID = trimmed(parts[2]);
                    if (locID.length) {
                        spoofLocaleID = locID;
                        // Do NOT derive ISO country from locale — country is always
                        // determined from coordinates via the geocoder, so that e.g.
                        // "en-US" locale with Vienna coords gives AT, not US.
                    }
                }
                if (parts.count >= 4) {
                    NSString *tzID = trimmed(parts[3]);
                    if (tzID.length && [NSTimeZone timeZoneWithName:tzID]) {
                        spoofTimezoneID = tzID;
                    } else if (tzID.length) {
                        debug_print(@"[LocationSpoof] Unknown timezone '%@', skipping", tzID);
                    }
                }
                debug_print(@"[LocationSpoof] Loaded: %.6f, %.6f, tz=%@, locale=%@, iso=%@",
                            spoofLat, spoofLon,
                            spoofTimezoneID ?: @"(none)", spoofLocaleID ?: @"(none)",
                            spoofISOCountryCode ?: @"(none)");
                return;
            }
        }
        debug_print(@"[LocationSpoof] location.txt parse failed, using default");
    } else {
        NSString *defaultContents = [NSString stringWithFormat:@"%.6f,%.6f,en-US,Asia/Jerusalem\n", spoofLat, spoofLon];
        [defaultContents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        debug_print(@"[LocationSpoof] Created location.txt with default: %.6f, %.6f, Asia/Jerusalem", spoofLat, spoofLon);
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

static CLLocation *fakeLocation(void) {
    return [[CLLocation alloc] initWithLatitude:spoofLat longitude:spoofLon];
}

static void fireAuthGranted(CLLocationManager *mgr, id<CLLocationManagerDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [delegate locationManagerDidChangeAuthorization:mgr];
    } else if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [delegate locationManager:mgr didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
#pragma clang diagnostic pop
    }
}

static void feedFakeLocation(CLLocationManager *mgr, id<CLLocationManagerDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:mgr didUpdateLocations:@[fakeLocation()]];
        //debug_print(@"[LocationSpoof] Injected fake location to delegate");
    }
}

// ─── Delegate proxy ───────────────────────────────────────────────────────────
//
// Sits between CLLocationManager and the real app delegate.
// Intercepts:
//   • didFailWithError:kCLErrorDenied  → suppress + inject fake location
//   • didChangeAuthorizationStatus:    → always report AuthorizedAlways
//   • locationManagerDidChangeAuthorization: (iOS 14+)  → same
// Forwards everything else unchanged.

@interface _LocationSpoofProxy : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id<CLLocationManagerDelegate> real;
@end

@implementation _LocationSpoofProxy

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied) {
        //debug_print(@"[LocationSpoof] Suppressed kCLErrorDenied, injecting fake location");
        dispatch_async(dispatch_get_main_queue(), ^{
            feedFakeLocation(manager, self.real);
        });
        return;
    }
    if ([self.real respondsToSelector:@selector(locationManager:didFailWithError:)])
        [self.real locationManager:manager didFailWithError:error];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    // authorizationStatus is already hooked to return AuthorizedAlways,
    // so just forward — the app will read the right value.
    if ([self.real respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
        [self.real locationManagerDidChangeAuthorization:manager];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)locationManager:(CLLocationManager *)manager
    didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if ([self.real respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)])
        [self.real locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
}
#pragma clang diagnostic pop

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.real respondsToSelector:sel];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    return sig ?: [(id)self.real methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    if ([self.real respondsToSelector:inv.selector])
        [inv invokeWithTarget:self.real];
}

@end

// Keyed by CLLocationManager pointer; retains proxies for their lifetime.
static NSMutableDictionary<NSValue *, _LocationSpoofProxy *> *proxyMap;

static _LocationSpoofProxy *proxyForManager(CLLocationManager *mgr) {
    NSValue *key = [NSValue valueWithPointer:(__bridge void *)mgr];
    _LocationSpoofProxy *p = proxyMap[key];
    if (!p) {
        p = [_LocationSpoofProxy new];
        proxyMap[key] = p;
    }
    return p;
}

// ─── Authorization status hooks ──────────────────────────────────────────────

static BOOL (*orig_locationServicesEnabled)(id, SEL);
static BOOL hooked_locationServicesEnabled(id self_, SEL _cmd) { return YES; }

static CLAuthorizationStatus (*orig_authorizationStatus_class)(id, SEL);
static CLAuthorizationStatus hooked_authorizationStatus_class(id self_, SEL _cmd) {
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAuthorizationStatus (*orig_authorizationStatus_instance)(id, SEL);
static CLAuthorizationStatus hooked_authorizationStatus_instance(id self_, SEL _cmd) {
    return kCLAuthorizationStatusAuthorizedAlways;
}

static CLAccuracyAuthorization hooked_accuracyAuthorization(id self_, SEL _cmd) {
    return CLAccuracyAuthorizationFullAccuracy;
}

// ─── setDelegate: hook — install the proxy ────────────────────────────────────

static void (*orig_setDelegate)(CLLocationManager *, SEL, id<CLLocationManagerDelegate>);
static void hooked_setDelegate(CLLocationManager *self_, SEL _cmd, id<CLLocationManagerDelegate> delegate) {
    if (delegate && ![delegate isKindOfClass:[_LocationSpoofProxy class]]) {
        _LocationSpoofProxy *proxy = proxyForManager(self_);
        proxy.real = delegate;
        orig_setDelegate(self_, _cmd, proxy);
    } else {
        orig_setDelegate(self_, _cmd, delegate);
    }
}

// ─── Permission request hooks — swallow + fire auth-granted callback ──────────

static void (*orig_requestAlwaysAuthorization)(id, SEL);
static void hooked_requestAlwaysAuthorization(CLLocationManager *self_, SEL _cmd) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        fireAuthGranted(self_, self_.delegate);
    });
}

static void (*orig_requestWhenInUseAuthorization)(id, SEL);
static void hooked_requestWhenInUseAuthorization(CLLocationManager *self_, SEL _cmd) {
    hooked_requestAlwaysAuthorization(self_, _cmd);
}

// ─── CLLocation -coordinate hook ─────────────────────────────────────────────

static CLLocationCoordinate2D (*orig_coordinate)(id, SEL);
static CLLocationCoordinate2D hooked_coordinate(id self_, SEL _cmd) {
    return CLLocationCoordinate2DMake(spoofLat, spoofLon);
}

// ─── startUpdating* hooks — inject fake location ─────────────────────────────

static void injectAfterStart(CLLocationManager *mgr) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        feedFakeLocation(mgr, mgr.delegate);
    });
}

static void (*orig_startUpdatingLocation)(id, SEL);
static void hooked_startUpdatingLocation(CLLocationManager *self_, SEL _cmd) {
    orig_startUpdatingLocation(self_, _cmd);
    injectAfterStart(self_);
}

static void (*orig_requestLocation)(id, SEL);
static void hooked_requestLocation(CLLocationManager *self_, SEL _cmd) {
    orig_requestLocation(self_, _cmd);
    injectAfterStart(self_);
}

static void (*orig_startMonitoringSignificantLocationChanges)(id, SEL);
static void hooked_startMonitoringSignificantLocationChanges(CLLocationManager *self_, SEL _cmd) {
    orig_startMonitoringSignificantLocationChanges(self_, _cmd);
    injectAfterStart(self_);
}

// ─── NSLocale hooks ───────────────────────────────────────────────────────────

static NSLocale *(*orig_currentLocale)(id, SEL);

static NSLocale *spoofedLocale(void) {
    if (spoofLocaleID.length) {
        return [NSLocale localeWithLocaleIdentifier:spoofLocaleID];
    }
    if (spoofISOCountryCode.length) {
        NSString *region = spoofISOCountryCode.uppercaseString;
        return [NSLocale localeWithLocaleIdentifier:[NSString stringWithFormat:@"en-%@", region]];
    }
    return nil;
}

static NSLocale *hooked_currentLocale(id self_, SEL _cmd) {
    NSLocale *locale = spoofedLocale();
    if (locale) return locale;
    return orig_currentLocale(self_, _cmd);
}

static NSLocale *(*orig_autoupdatingCurrentLocale)(id, SEL);
static NSLocale *hooked_autoupdatingCurrentLocale(id self_, SEL _cmd) {
    NSLocale *locale = spoofedLocale();
    if (locale) return locale;
    return orig_autoupdatingCurrentLocale(self_, _cmd);
}

static NSArray<NSString *> *(*orig_preferredLanguages)(id, SEL);
static NSArray<NSString *> *hooked_preferredLanguages(id self_, SEL _cmd) {
    if (spoofLocaleID.length) return @[spoofLocaleID];
    return orig_preferredLanguages(self_, _cmd);
}

static NSString *(*orig_localeCountryCode)(id, SEL);
static NSString *hooked_localeCountryCode(id self_, SEL _cmd) {
    if (spoofISOCountryCode.length) return spoofISOCountryCode.uppercaseString;
    return orig_localeCountryCode ? orig_localeCountryCode(self_, _cmd) : nil;
}

// Swift's (Locale.current as NSLocale).object(forKey: .countryCode) calls
// -[NSLocale objectForKey:] directly, bypassing the countryCode property getter.
static id (*orig_localeObjectForKey)(id, SEL, NSLocaleKey);
static id hooked_localeObjectForKey(id self_, SEL _cmd, NSLocaleKey key) {
    if (spoofISOCountryCode.length && [key isEqualToString:NSLocaleCountryCode])
        return spoofISOCountryCode.uppercaseString;
    return orig_localeObjectForKey(self_, _cmd, key);
}

// ─── Telephony hooks (CTCarrier / CTTelephonyNetworkInfo) ───────────────────

static NSString *(*orig_isoCountryCode)(id, SEL);
static NSString *hooked_isoCountryCode(id self_, SEL _cmd) {
    if (spoofISOCountryCode.length) return spoofISOCountryCode;
    return orig_isoCountryCode ? orig_isoCountryCode(self_, _cmd) : nil;
}

static NSString *(*orig_mobileCountryCode)(id, SEL);
static NSString *hooked_mobileCountryCode(id self_, SEL _cmd) {
    if (spoofMobileCountryCode.length) return spoofMobileCountryCode;
    return orig_mobileCountryCode ? orig_mobileCountryCode(self_, _cmd) : nil;
}

static NSString *(*orig_mobileNetworkCode)(id, SEL);
static NSString *hooked_mobileNetworkCode(id self_, SEL _cmd) {
    if (spoofISOCountryCode.length) {
        return spoofMobileNetworkCode.length ? spoofMobileNetworkCode : @"01";
    }
    return orig_mobileNetworkCode ? orig_mobileNetworkCode(self_, _cmd) : nil;
}

static id (*orig_subscriberCellularProvider)(id, SEL);
static NSDictionary<NSString *, id> *(*orig_serviceSubscriberCellularProviders)(id, SEL);

static id fallbackCarrier(void) {
    static id carrier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class ctCarrier = NSClassFromString(@"CTCarrier");
        if (ctCarrier) carrier = [ctCarrier new];
    });
    return carrier;
}

static id hooked_subscriberCellularProvider(id self_, SEL _cmd) {
    id provider = orig_subscriberCellularProvider ? orig_subscriberCellularProvider(self_, _cmd) : nil;
    if (provider) return provider;
    if (spoofISOCountryCode.length) return fallbackCarrier();
    return nil;
}

static NSDictionary<NSString *, id> *hooked_serviceSubscriberCellularProviders(id self_, SEL _cmd) {
    NSDictionary<NSString *, id> *providers =
        orig_serviceSubscriberCellularProviders ? orig_serviceSubscriberCellularProviders(self_, _cmd) : nil;
    if (providers.count) return providers;

    if (spoofISOCountryCode.length) {
        id provider = fallbackCarrier();
        if (provider) {
            return @{@"spoof_service": provider};
        }
    }
    return @{};
}

// ─── Phone number hooks ───────────────────────────────────────────────────────

static CFStringRef (*orig_CTSettingCopyMyPhoneNumber)(void);
static CFStringRef hooked_CTSettingCopyMyPhoneNumber(void) {
    if (spoofPhoneNumber) return (__bridge_retained CFStringRef)spoofPhoneNumber;
    return orig_CTSettingCopyMyPhoneNumber ? orig_CTSettingCopyMyPhoneNumber() : NULL;
}

static NSString *(*orig_devicePhoneNumber)(id, SEL);
static NSString *hooked_devicePhoneNumber(id self_, SEL _cmd) {
    if (spoofPhoneNumber) return spoofPhoneNumber;
    return orig_devicePhoneNumber ? orig_devicePhoneNumber(self_, _cmd) : nil;
}

// Forward-declared here because applyTimezone calls it before the hook block defines it.
static void (*orig_setDefaultTimeZone)(id, SEL, NSTimeZone *);

// ─── Timezone application ─────────────────────────────────────────────────────
// Called both from init() (explicit TZ in location.txt) and from the geocoder
// callback (auto-detected from coordinates).

static void applyTimezone(NSString *tzID) {
    spoofTimezoneID = tzID;
    setenv("TZ", tzID.UTF8String, 1);
    tzset();
    [NSTimeZone resetSystemTimeZone];
    NSTimeZone *spoofTZ = [NSTimeZone timeZoneWithName:tzID];
    // Call orig directly — hooked_setDefaultTimeZone is already installed and would swallow this.
    if (orig_setDefaultTimeZone)
        orig_setDefaultTimeZone([NSTimeZone class], @selector(setDefaultTimeZone:), spoofTZ);
    else
        [NSTimeZone setDefaultTimeZone:spoofTZ];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSSystemTimeZoneDidChangeNotification object:nil];
    debug_print(@"[LocationSpoof] Timezone applied: %@", tzID);
}

// ─── NSTimeZone hooks ─────────────────────────────────────────────────────────

static NSTimeZone *(*orig_localTimeZone)(id, SEL);
static NSTimeZone *hooked_localTimeZone(id self_, SEL _cmd) {
    if (spoofTimezoneID) return [NSTimeZone timeZoneWithName:spoofTimezoneID];
    return orig_localTimeZone(self_, _cmd);
}

static NSTimeZone *(*orig_systemTimeZone)(id, SEL);
static NSTimeZone *hooked_systemTimeZone(id self_, SEL _cmd) {
    if (spoofTimezoneID) return [NSTimeZone timeZoneWithName:spoofTimezoneID];
    return orig_systemTimeZone(self_, _cmd);
}

static NSTimeZone *(*orig_defaultTimeZone)(id, SEL);
static NSTimeZone *hooked_defaultTimeZone(id self_, SEL _cmd) {
    if (spoofTimezoneID) return [NSTimeZone timeZoneWithName:spoofTimezoneID];
    return orig_defaultTimeZone(self_, _cmd);
}

static void hooked_setDefaultTimeZone(id self_, SEL _cmd, NSTimeZone *tz) {
    // Silently ignore — our spoofed timezone stays in place.
}

// ─── UIDevice private region hooks ───────────────────────────────────────────

static NSString *(*orig_sfRegionCode)(id, SEL);
static NSString *hooked_sfRegionCode(id self_, SEL _cmd) {
    if (spoofISOCountryCode.length) return spoofISOCountryCode.uppercaseString;
    return orig_sfRegionCode ? orig_sfRegionCode(self_, _cmd) : nil;
}

// ─── CFLocale hooks (fishhook) ────────────────────────────────────────────────
// Swift and CF APIs call CFLocaleCopyCurrent() directly, bypassing
// +[NSLocale currentLocale] and the ObjC hooks above.

static CFLocaleRef (*orig_CFLocaleCopyCurrent)(void);
static CFLocaleRef hooked_CFLocaleCopyCurrent(void) {
    NSString *locID = spoofLocaleID.length ? spoofLocaleID
                    : (spoofISOCountryCode.length
                       ? [NSString stringWithFormat:@"en_%@", spoofISOCountryCode.uppercaseString]
                       : nil);
    if (locID) return CFLocaleCreate(kCFAllocatorDefault, (__bridge CFStringRef)locID);
    return orig_CFLocaleCopyCurrent();
}

static CFArrayRef (*orig_CFLocaleCopyPreferredLanguages)(void);
static CFArrayRef hooked_CFLocaleCopyPreferredLanguages(void) {
    if (spoofLocaleID.length)
        return (__bridge_retained CFArrayRef)@[spoofLocaleID];
    return orig_CFLocaleCopyPreferredLanguages();
}

// ─── CFTimeZone hooks (fishhook) ──────────────────────────────────────────────
// NSDateFormatter and most CF/Swift date APIs call these C functions directly,
// bypassing the ObjC method hooks above.

static CFTimeZoneRef (*orig_CFTimeZoneCopyDefault)(void);
static CFTimeZoneRef hooked_CFTimeZoneCopyDefault(void) {
    if (spoofTimezoneID) return (CFTimeZoneRef)CFBridgingRetain([NSTimeZone timeZoneWithName:spoofTimezoneID]);
    return orig_CFTimeZoneCopyDefault();
}

static CFTimeZoneRef (*orig_CFTimeZoneCopySystem)(void);
static CFTimeZoneRef hooked_CFTimeZoneCopySystem(void) {
    if (spoofTimezoneID) return (CFTimeZoneRef)CFBridgingRetain([NSTimeZone timeZoneWithName:spoofTimezoneID]);
    return orig_CFTimeZoneCopySystem();
}

// ─── File watcher ─────────────────────────────────────────────────────────────

static void setupLocationFileWatcher(void);

static void setupLocationFileWatcher(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"location.txt"];
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        // File absent — watch Documents directory until location.txt appears.
        // Coords remain at their current values (defaults or last loaded).
        int dirFd = open(docs.fileSystemRepresentation, O_EVTONLY);
        if (dirFd < 0) return;

        dispatch_source_t dirSrc = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)dirFd,
            DISPATCH_VNODE_WRITE,
            q);

        dispatch_source_set_event_handler(dirSrc, ^{
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                dispatch_source_cancel(dirSrc);
                loadCoordinates();
                setupLocationFileWatcher();
            }
        });

        dispatch_source_set_cancel_handler(dirSrc, ^{ close(dirFd); });
        dispatch_resume(dirSrc);
        return;
    }

    // File exists — watch it directly.
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
        q);

    dispatch_source_set_event_handler(src, ^{
        unsigned long flags = dispatch_source_get_data(src);
        loadCoordinates();
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
            // File gone — cancel and fall back to directory watch.
            // Last loaded coords remain active.
            dispatch_source_cancel(src);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), q, ^{
                setupLocationFileWatcher();
            });
        }
    });

    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    dispatch_resume(src);
}

// ─── WKWebView JS timezone injection ─────────────────────────────────────────

static NSString *buildTZScript(NSString *tzID) {
    return [NSString stringWithFormat:
        @"(function(){"
         "  const SPOOF_TZ = '%@';"
         "  const _OrigDTF = Intl.DateTimeFormat;"
         "  function patchedDTF(loc, opts) {"
         "    if (opts && opts.timeZone) return new _OrigDTF(loc, opts);"
         "    const merged = Object.assign({}, opts, {timeZone: SPOOF_TZ});"
         "    const fmt = new _OrigDTF(loc, merged);"
         "    const origRO = fmt.resolvedOptions.bind(fmt);"
         "    fmt.resolvedOptions = function() { const r = origRO(); r.timeZone = SPOOF_TZ; return r; };"
         "    return fmt;"
         "  }"
         "  patchedDTF.prototype = _OrigDTF.prototype;"
         "  patchedDTF.supportedLocalesOf = _OrigDTF.supportedLocalesOf.bind(_OrigDTF);"
         "  Intl.DateTimeFormat = patchedDTF;"
         "  const _origGTO = Date.prototype.getTimezoneOffset;"
         "  Date.prototype.getTimezoneOffset = function() {"
         "    const d = this;"
         "    const utcMs = Date.UTC(d.getUTCFullYear(),d.getUTCMonth(),d.getUTCDate(),"
         "                          d.getUTCHours(),d.getUTCMinutes(),d.getUTCSeconds());"
         "    const local = new _OrigDTF('en-US',{timeZone:SPOOF_TZ,"
         "                  year:'numeric',month:'2-digit',day:'2-digit',"
         "                  hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false});"
         "    const p = local.formatToParts(d).reduce((a,x)=>(a[x.type]=x.value,a),{});"
         "    const localMs = Date.UTC(+p.year,+p.month-1,+p.day,"
         "                            p.hour==='24'?0:+p.hour,+p.minute,+p.second);"
         "    return (utcMs - localMs) / 60000;"
         "  };"
         "})();",
        tzID];
}

static id (*orig_WKWebView_initWithFrame_configuration)(id, SEL, CGRect, id);
static id hooked_WKWebView_initWithFrame_configuration(id self_, SEL _cmd, CGRect frame, id configuration) {
    id wkview = orig_WKWebView_initWithFrame_configuration(self_, _cmd, frame, configuration);
    NSString *tz = spoofTimezoneID ?: @"UTC";
    NSString *script = buildTZScript(tz);
    Class WKUserScript = NSClassFromString(@"WKUserScript");
    Class WKUContentController = NSClassFromString(@"WKUserContentController");
    if (!WKUserScript || !WKUContentController) return wkview;
    // WKUserScriptInjectionTimeAtDocumentStart = 0
    typedef id (*WKUserScript_init_t)(id, SEL, NSString *, NSInteger, BOOL);
    SEL initSel = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    id us = ((WKUserScript_init_t)objc_msgSend)([WKUserScript alloc], initSel, script, (NSInteger)0, NO);
    id ucc = [configuration valueForKey:@"userContentController"];
    if (ucc) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [ucc performSelector:NSSelectorFromString(@"addUserScript:") withObject:us];
#pragma clang diagnostic pop
    }
    debug_print(@"[LocationSpoof] Injected TZ script into WKWebView (tz=%@)", tz);
    return wkview;
}

static void injectWKWebView(void) {
    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) { debug_print(@"[LocationSpoof] WKWebView not found, skipping JS injection"); return; }
    SEL sel = @selector(initWithFrame:configuration:);
    Method m = class_getInstanceMethod(wk, sel);
    if (!m) { debug_print(@"[LocationSpoof] WKWebView initWithFrame:configuration: not found"); return; }
    orig_WKWebView_initWithFrame_configuration =
        (id (*)(id, SEL, CGRect, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_WKWebView_initWithFrame_configuration);
    debug_print(@"[LocationSpoof] WKWebView hook installed");
}

// ─── Init ─────────────────────────────────────────────────────────────────────

void init() {
    setenv("TZ", "UTC", 1);
    loadCoordinates();
    loadPhoneNumber();
    injectWKWebView();
    setupLocationFileWatcher();
    proxyMap = [NSMutableDictionary new];

    Class loc = [CLLocation class];
    Method coord = class_getInstanceMethod(loc, @selector(coordinate));
    orig_coordinate = (CLLocationCoordinate2D (*)(id, SEL))method_getImplementation(coord);
    method_setImplementation(coord, (IMP)hooked_coordinate);

    Class mgr = [CLLocationManager class];

    Method lse = class_getClassMethod(mgr, @selector(locationServicesEnabled));
    orig_locationServicesEnabled = (BOOL (*)(id, SEL))method_getImplementation(lse);
    method_setImplementation(lse, (IMP)hooked_locationServicesEnabled);

    Method authC = class_getClassMethod(mgr, @selector(authorizationStatus));
    orig_authorizationStatus_class = (CLAuthorizationStatus (*)(id, SEL))method_getImplementation(authC);
    method_setImplementation(authC, (IMP)hooked_authorizationStatus_class);

    Method authI = class_getInstanceMethod(mgr, @selector(authorizationStatus));
    if (authI) {
        orig_authorizationStatus_instance = (CLAuthorizationStatus (*)(id, SEL))method_getImplementation(authI);
        method_setImplementation(authI, (IMP)hooked_authorizationStatus_instance);
    }

    Method aa = class_getInstanceMethod(mgr, @selector(accuracyAuthorization));
    if (aa) {
        method_setImplementation(aa, (IMP)hooked_accuracyAuthorization);
    }

    Method sd = class_getInstanceMethod(mgr, @selector(setDelegate:));
    orig_setDelegate = (void (*)(CLLocationManager *, SEL, id<CLLocationManagerDelegate>))method_getImplementation(sd);
    method_setImplementation(sd, (IMP)hooked_setDelegate);

    Method raa = class_getInstanceMethod(mgr, @selector(requestAlwaysAuthorization));
    orig_requestAlwaysAuthorization = (void (*)(id, SEL))method_getImplementation(raa);
    method_setImplementation(raa, (IMP)hooked_requestAlwaysAuthorization);

    Method rwia = class_getInstanceMethod(mgr, @selector(requestWhenInUseAuthorization));
    orig_requestWhenInUseAuthorization = (void (*)(id, SEL))method_getImplementation(rwia);
    method_setImplementation(rwia, (IMP)hooked_requestWhenInUseAuthorization);

    Method sul = class_getInstanceMethod(mgr, @selector(startUpdatingLocation));
    orig_startUpdatingLocation = (void (*)(id, SEL))method_getImplementation(sul);
    method_setImplementation(sul, (IMP)hooked_startUpdatingLocation);

    Method rl = class_getInstanceMethod(mgr, @selector(requestLocation));
    orig_requestLocation = (void (*)(id, SEL))method_getImplementation(rl);
    method_setImplementation(rl, (IMP)hooked_requestLocation);

    Method smlc = class_getInstanceMethod(mgr, @selector(startMonitoringSignificantLocationChanges));
    orig_startMonitoringSignificantLocationChanges = (void (*)(id, SEL))method_getImplementation(smlc);
    method_setImplementation(smlc, (IMP)hooked_startMonitoringSignificantLocationChanges);

    {
        Class lc = [NSLocale class];

        Method cur = class_getClassMethod(lc, @selector(currentLocale));
        orig_currentLocale = (NSLocale *(*)(id, SEL))method_getImplementation(cur);
        method_setImplementation(cur, (IMP)hooked_currentLocale);

        Method auc = class_getClassMethod(lc, @selector(autoupdatingCurrentLocale));
        orig_autoupdatingCurrentLocale = (NSLocale *(*)(id, SEL))method_getImplementation(auc);
        method_setImplementation(auc, (IMP)hooked_autoupdatingCurrentLocale);

        Method pl = class_getClassMethod(lc, @selector(preferredLanguages));
        orig_preferredLanguages = (NSArray<NSString *> *(*)(id, SEL))method_getImplementation(pl);
        method_setImplementation(pl, (IMP)hooked_preferredLanguages);

        Method cc = class_getInstanceMethod(lc, @selector(countryCode));
        if (cc) {
            orig_localeCountryCode = (NSString *(*)(id, SEL))method_getImplementation(cc);
            method_setImplementation(cc, (IMP)hooked_localeCountryCode);
        }

        Method okf = class_getInstanceMethod(lc, @selector(objectForKey:));
        if (okf) {
            orig_localeObjectForKey = (id (*)(id, SEL, NSLocaleKey))method_getImplementation(okf);
            method_setImplementation(okf, (IMP)hooked_localeObjectForKey);
        }
    }

    {
        Class uiDevice = NSClassFromString(@"UIDevice");
        if (uiDevice) {
            SEL sfSel = NSSelectorFromString(@"sf_regionCode");
            Method sfRegion = class_getInstanceMethod(uiDevice, sfSel);
            if (sfRegion) {
                orig_sfRegionCode = (NSString *(*)(id, SEL))method_getImplementation(sfRegion);
                method_setImplementation(sfRegion, (IMP)hooked_sfRegionCode);
                debug_print(@"[LocationSpoof] UIDevice sf_regionCode hooked");
            } else {
                // Method may not exist yet — add it so it's intercepted if called dynamically.
                class_addMethod(uiDevice, sfSel, (IMP)hooked_sfRegionCode, "@@:");
            }

            SEL pnSel = NSSelectorFromString(@"phoneNumber");
            Method pn = class_getInstanceMethod(uiDevice, pnSel);
            if (pn) {
                orig_devicePhoneNumber = (NSString *(*)(id, SEL))method_getImplementation(pn);
                method_setImplementation(pn, (IMP)hooked_devicePhoneNumber);
                debug_print(@"[LocationSpoof] UIDevice phoneNumber hooked");
            }
        }
    }

    {
        Class ctCarrier = NSClassFromString(@"CTCarrier");
        if (ctCarrier) {
            debug_print(@"[LocationSpoof] CTCarrier class found, installing telephony hooks");
            Method iso = class_getInstanceMethod(ctCarrier, NSSelectorFromString(@"isoCountryCode"));
            if (iso) {
                orig_isoCountryCode = (NSString *(*)(id, SEL))method_getImplementation(iso);
                method_setImplementation(iso, (IMP)hooked_isoCountryCode);
            }

            Method mcc = class_getInstanceMethod(ctCarrier, NSSelectorFromString(@"mobileCountryCode"));
            if (mcc) {
                orig_mobileCountryCode = (NSString *(*)(id, SEL))method_getImplementation(mcc);
                method_setImplementation(mcc, (IMP)hooked_mobileCountryCode);
            }

            Method mnc = class_getInstanceMethod(ctCarrier, NSSelectorFromString(@"mobileNetworkCode"));
            if (mnc) {
                orig_mobileNetworkCode = (NSString *(*)(id, SEL))method_getImplementation(mnc);
                method_setImplementation(mnc, (IMP)hooked_mobileNetworkCode);
            }
        }

        Class tni = NSClassFromString(@"CTTelephonyNetworkInfo");
        if (tni) {
            Method scp = class_getInstanceMethod(tni, NSSelectorFromString(@"subscriberCellularProvider"));
            if (scp) {
                orig_subscriberCellularProvider = (id (*)(id, SEL))method_getImplementation(scp);
                method_setImplementation(scp, (IMP)hooked_subscriberCellularProvider);
            }

            Method sscp = class_getInstanceMethod(tni, NSSelectorFromString(@"serviceSubscriberCellularProviders"));
            if (sscp) {
                orig_serviceSubscriberCellularProviders =
                    (NSDictionary<NSString *, id> *(*)(id, SEL))method_getImplementation(sscp);
                method_setImplementation(sscp, (IMP)hooked_serviceSubscriberCellularProviders);
            }
        }
    }

    // Install all timezone hooks unconditionally — they guard on spoofTimezoneID at call time.
    {
        Class tz = [NSTimeZone class];

        Method ltz = class_getClassMethod(tz, @selector(localTimeZone));
        orig_localTimeZone = (NSTimeZone *(*)(id, SEL))method_getImplementation(ltz);
        method_setImplementation(ltz, (IMP)hooked_localTimeZone);

        Method stz = class_getClassMethod(tz, @selector(systemTimeZone));
        orig_systemTimeZone = (NSTimeZone *(*)(id, SEL))method_getImplementation(stz);
        method_setImplementation(stz, (IMP)hooked_systemTimeZone);

        Method dtz = class_getClassMethod(tz, @selector(defaultTimeZone));
        orig_defaultTimeZone = (NSTimeZone *(*)(id, SEL))method_getImplementation(dtz);
        method_setImplementation(dtz, (IMP)hooked_defaultTimeZone);

        Method sdtz = class_getClassMethod(tz, @selector(setDefaultTimeZone:));
        orig_setDefaultTimeZone = (void (*)(id, SEL, NSTimeZone *))method_getImplementation(sdtz);
        method_setImplementation(sdtz, (IMP)hooked_setDefaultTimeZone);

        struct rebinding tz_rebindings[] = {
            {"CFTimeZoneCopyDefault",           hooked_CFTimeZoneCopyDefault,           (void **)&orig_CFTimeZoneCopyDefault},
            {"CFTimeZoneCopySystem",            hooked_CFTimeZoneCopySystem,             (void **)&orig_CFTimeZoneCopySystem},
            {"CFLocaleCopyCurrent",             hooked_CFLocaleCopyCurrent,              (void **)&orig_CFLocaleCopyCurrent},
            {"CFLocaleCopyPreferredLanguages",  hooked_CFLocaleCopyPreferredLanguages,   (void **)&orig_CFLocaleCopyPreferredLanguages},
            {"CTSettingCopyMyPhoneNumber",      hooked_CTSettingCopyMyPhoneNumber,       (void **)&orig_CTSettingCopyMyPhoneNumber},
        };
        rebind_symbols(tz_rebindings, 5);
    }

    BOOL needsTimezoneFromGeocoder = !spoofTimezoneID;
    BOOL needsCountryFromGeocoder = !spoofISOCountryCode;

    // Apply UTC immediately so hooks never passthrough to the real timezone
    // during the async geocoder delay.
    if (needsTimezoneFromGeocoder) applyTimezone(@"UTC");

    if (!needsTimezoneFromGeocoder && !needsCountryFromGeocoder) {
        applyTimezone(spoofTimezoneID);
    } else {
        // Reverse-geocode spoofed coordinates for missing timezone/country data.
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:spoofLat longitude:spoofLon];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[CLGeocoder new] reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
            CLPlacemark *placemark = placemarks.firstObject;

            if (needsCountryFromGeocoder) {
                NSString *iso = normalizedISOCountryCode(placemark.ISOcountryCode);
                if (iso.length) {
                    applyISOCountryCode(iso);
                } else {
                    debug_print(@"[LocationSpoof] Geocoder failed to determine carrier country: %@", error);
                }
            }

            if (needsTimezoneFromGeocoder) {
                NSTimeZone *tz = placemark.timeZone;
                if (tz) {
                    NSString *tzName = [tz.name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
                    applyTimezone(tzName);
                } else {
                    debug_print(@"[LocationSpoof] Geocoder failed to determine timezone: %@", error);
                }
            } else if (spoofTimezoneID) {
                applyTimezone(spoofTimezoneID);
            }
            if (!placemark) {
                debug_print(@"[LocationSpoof] Geocoder failed to determine timezone: %@", error);
            }
        }];
#pragma clang diagnostic pop
    }

    debug_print(@"[LocationSpoof] Hooks installed (%.6f, %.6f%@%@%@%@)", spoofLat, spoofLon,
                spoofTimezoneID ? [NSString stringWithFormat:@", tz=%@", spoofTimezoneID] : @"",
                spoofISOCountryCode ? [NSString stringWithFormat:@", iso=%@", spoofISOCountryCode] : @"",
                spoofMobileCountryCode ? [NSString stringWithFormat:@", mcc=%@", spoofMobileCountryCode] : @"",
                spoofPhoneNumber ? [NSString stringWithFormat:@", phone=%@", spoofPhoneNumber] : @"");
}
