#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#import "utils.h"

// ─── Spoofed coordinates + timezone + locale ─────────────────────────────────
// Loaded from <Documents>/location.txt ("lat,lon[,Timezone/Name[,locale]]"),
// e.g. "31.041,32.194,Asia/Jerusalem,en-US"
// Omit trailing fields to skip that spoofing. Defaults to Tel Aviv / Asia/Jerusalem.

static CLLocationDegrees spoofLat = 32.084270;
static CLLocationDegrees spoofLon = 34.769603;
static NSString *spoofTimezoneID  = nil; // nil = no timezone spoofing
static NSString *spoofLocaleID    = nil; // nil = no locale spoofing

static NSString *trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
                    NSString *tzID = trimmed(parts[2]);
                    if (tzID.length && [NSTimeZone timeZoneWithName:tzID]) {
                        spoofTimezoneID = tzID;
                    } else if (tzID.length) {
                        debug_print(@"[LocationSpoof] Unknown timezone '%@', skipping", tzID);
                    }
                }
                if (parts.count >= 4) {
                    NSString *locID = trimmed(parts[3]);
                    // Accept any non-empty string — NSLocale is lenient with unknown IDs.
                    if (locID.length) spoofLocaleID = locID;
                }
                debug_print(@"[LocationSpoof] Loaded: %.6f, %.6f, tz=%@, locale=%@",
                            spoofLat, spoofLon,
                            spoofTimezoneID ?: @"(none)", spoofLocaleID ?: @"(none)");
                return;
            }
        }
        debug_print(@"[LocationSpoof] location.txt parse failed, using default");
    } else {
        NSString *defaultContents = [NSString stringWithFormat:@"%.6f,%.6f,Asia/Jerusalem\n", spoofLat, spoofLon];
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
static NSLocale *hooked_currentLocale(id self_, SEL _cmd) {
    if (spoofLocaleID) return [NSLocale localeWithLocaleIdentifier:spoofLocaleID];
    return orig_currentLocale(self_, _cmd);
}

static NSLocale *(*orig_autoupdatingCurrentLocale)(id, SEL);
static NSLocale *hooked_autoupdatingCurrentLocale(id self_, SEL _cmd) {
    if (spoofLocaleID) return [NSLocale localeWithLocaleIdentifier:spoofLocaleID];
    return orig_autoupdatingCurrentLocale(self_, _cmd);
}

static NSArray<NSString *> *(*orig_preferredLanguages)(id, SEL);
static NSArray<NSString *> *hooked_preferredLanguages(id self_, SEL _cmd) {
    if (spoofLocaleID) return @[spoofLocaleID];
    return orig_preferredLanguages(self_, _cmd);
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

// ─── Init ─────────────────────────────────────────────────────────────────────

void init() {
    loadCoordinates();
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

    if (spoofLocaleID) {
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
    }

    if (spoofTimezoneID) {
        Class tz = [NSTimeZone class];
        Method ltz = class_getClassMethod(tz, @selector(localTimeZone));
        orig_localTimeZone = (NSTimeZone *(*)(id, SEL))method_getImplementation(ltz);
        method_setImplementation(ltz, (IMP)hooked_localTimeZone);

        Method stz = class_getClassMethod(tz, @selector(systemTimeZone));
        orig_systemTimeZone = (NSTimeZone *(*)(id, SEL))method_getImplementation(stz);
        method_setImplementation(stz, (IMP)hooked_systemTimeZone);
    }

    debug_print(@"[LocationSpoof] Hooks installed (%.6f, %.6f%@)", spoofLat, spoofLon,
                spoofTimezoneID ? [NSString stringWithFormat:@", %@", spoofTimezoneID] : @"");
}
