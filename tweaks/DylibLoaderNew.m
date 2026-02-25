#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sys/socket.h>
#import <unistd.h>

#import <objc/message.h>
#import <objc/runtime.h>

#import "utils/logger2.m"

// ── All LiveContainer symbols resolved purely at runtime ──
// No linker references — uses NSClassFromString / dlsym / objc_msgSend.
// LCUtils is NOT available in the guest process, so we call ZSigner directly.

// ── Sign all dylibs in a folder via ZSign (same pipeline as LCUtils) ──
//   1. Copy dylibs into a temporary .app wrapper
//   2. Load ZSign.dylib, get provisioning profile + cert from the host
//   3. Call [ZSigner signWithAppPath:prov:key:pass:completionHandler:]
//   4. Move signed dylibs back, clean up
static BOOL signReceivedTweaks(NSString *tweakDir,
                               NSArray<NSString *> *fileNames) {
  // Get LiveContainer's original bundle via the lcMainBundle global
  // (set in LCBootstrap.m before mainBundle is swizzled to the guest app)
  NSBundle **lcMainBundlePtr = (NSBundle **)dlsym(RTLD_DEFAULT, "lcMainBundle");
  NSBundle *hostBundle = lcMainBundlePtr ? *lcMainBundlePtr : nil;
  if (!hostBundle) {
    debug_print(@"[DylibLoader] lcMainBundle not found via dlsym.");
    return NO;
  }

  // lcMainBundle may point to LiveProcess.appex — walk up to the main .app
  NSString *bundlePath = hostBundle.bundlePath;
  if ([bundlePath.pathExtension isEqualToString:@"appex"]) {
    NSString *mainAppPath = [[bundlePath stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent];
    NSBundle *mainAppBundle = [NSBundle bundleWithPath:mainAppPath];
    if (mainAppBundle) {
      hostBundle = mainAppBundle;
    }
  }
  debug_print(@"[DylibLoader] Host bundle: %@", hostBundle.bundlePath);

  // Load OpenSSL.framework then ZSign.dylib from the host bundle's Frameworks
  NSString *frameworksDir =
      [hostBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];

  static BOOL opensslLoaded = NO;
  if (!opensslLoaded) {
    NSString *opensslPath = [frameworksDir
        stringByAppendingPathComponent:@"OpenSSL.framework/OpenSSL"];
    void *sslHandle = dlopen(opensslPath.UTF8String, RTLD_GLOBAL);
    if (!sslHandle) {
      debug_print(@"[DylibLoader] Failed to load OpenSSL: %s", dlerror());
      return NO;
    }
    opensslLoaded = YES;
    debug_print(@"[DylibLoader] OpenSSL loaded.");
  }

  static BOOL zsignLoaded = NO;
  if (!zsignLoaded) {
    NSString *zsignDylibPath =
        [frameworksDir stringByAppendingPathComponent:@"ZSign.dylib"];
    void *zsignHandle = dlopen(zsignDylibPath.UTF8String, RTLD_GLOBAL);
    if (!zsignHandle) {
      debug_print(@"[DylibLoader] Failed to load ZSign.dylib: %s", dlerror());
      return NO;
    }
    zsignLoaded = YES;
    debug_print(@"[DylibLoader] ZSign.dylib loaded.");
  }

  Class ZSigner = NSClassFromString(@"ZSigner");
  if (!ZSigner) {
    debug_print(@"[DylibLoader] ZSigner class not found.");
    return NO;
  }

  // Sign each dylib directly via +[ZSigner
  // adhocSignMachOAtPath:bundleId:entitlementData:]
  SEL adhocSel =
      NSSelectorFromString(@"adhocSignMachOAtPath:bundleId:entitlementData:");
  NSString *bundleId =
      hostBundle.bundleIdentifier ?: @"com.livecontainer.tweaks";

  BOOL allOK = YES;
  for (NSString *name in fileNames) {
    NSString *fullPath = [tweakDir stringByAppendingPathComponent:name];
    debug_print(@"[DylibLoader] Signing %@ …", fullPath);

    BOOL ok =
        ((BOOL(*)(id, SEL, NSString *, NSString *, NSData *))objc_msgSend)(
            ZSigner, adhocSel, fullPath, bundleId, nil);

    if (ok) {
      debug_print(@"[DylibLoader] Signed %@ OK.", name);
    } else {
      debug_print(@"[DylibLoader] Failed to sign %@!", name);
      allOK = NO;
    }
  }

  debug_print(@"[DylibLoader] Signing complete, allOK=%d", allOK);
  return allOK;
}

// Use BOOL for return type and correctly handle file writing
BOOL recv_to_file(int sock, FILE *fp, size_t total_len) {
  char buffer[8192];
  size_t received_so_far = 0;

  while (received_so_far < total_len) {
    // Calculate how much we still need, but don't exceed our 8KB buffer
    size_t to_read = total_len - received_so_far;
    if (to_read > sizeof(buffer))
      to_read = sizeof(buffer);

    ssize_t r = recv(sock, buffer, to_read, 0);

    if (r <= 0) {
      return NO; // Socket closed or error
    }

    // Write the chunk we just got to the file
    if (fwrite(buffer, 1, r, fp) != r) {
      return NO; // Disk full or permissions error
    }

    received_so_far += r;
  }
  return YES;
}

void start_bridge_listener() {
  int sock = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  addr.sin_family = AF_INET;
  addr.sin_port = htons(8887);
  addr.sin_addr.s_addr = inet_addr("192.168.1.23");

  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    exit(1);

  // Receive "READY"
  debug_print(@"Recving ready");
  char junk[1024];
  recv(sock, junk, sizeof(junk), 0);
  debug_print(@"Recving count");
  // Receive Number of Dylibs
  uint32_t dylib_count = 0;
  recv(sock, &dylib_count, 4, 0);
  debug_print(@"[DylibLoader] Count 1: %d", dylib_count);
  dylib_count = ntohl(dylib_count);
  debug_print(@"[DylibLoader] Count 2: %d", dylib_count);
  debug_print(@"[DylibLoader] Count 3: %d", dylib_count);

  NSString *basePath = [@"/private/var/mobile/Containers/Data/Application/"
                        @"EF9EB8C3-C3CA-4E39-92A6-A005FD1292EB/"
      stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
  [[NSFileManager defaultManager] createDirectoryAtPath:basePath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  void **objs = malloc(sizeof(void *) * dylib_count);
  NSMutableArray<NSString *> *receivedNames =
      [NSMutableArray arrayWithCapacity:dylib_count];

  // ── Phase 1: Receive all dylibs to disk ──
  for (int i = 0; i < dylib_count; i++) {
    // Receive Name
    uint32_t name_len = 0;
    recv(sock, &name_len, 4, 0);
    char *name_buf = malloc(name_len + 1);
    recv(sock, name_buf, name_len, 0);
    name_buf[name_len] = '\0';

    // Receive Data
    uint32_t data_len = 0;
    recv(sock, &data_len, 4, 0);
    data_len = ntohl(data_len);

    NSString *fileName = [NSString stringWithUTF8String:name_buf];
    NSString *fullPath = [basePath stringByAppendingPathComponent:fileName];
    const char *path = [fullPath UTF8String];
    debug_print(@"[DylibLoader] #%d needs to recv %d into %s", i, data_len,
                path);

    // Clean start
    unlink(path);

    FILE *fp = fopen(path, "wb");
    if (!fp) {
      exit(1);
    }

    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"[DylibLoader] ERROR: Cannot recv %s.", path);
      exit(1);
    }
    fclose(fp);
    [receivedNames addObject:fileName];
    free(name_buf);
  }

  // ── Phase 2: Sign all received tweaks via LiveContainer's ZSign ──
  debug_print(@"[DylibLoader] Signing %lu received tweaks…",
              (unsigned long)receivedNames.count);
  if (!signReceivedTweaks(basePath, receivedNames)) {
    debug_print(@"[DylibLoader] WARNING: Signing failed — dlopen may fail on "
                @"JIT-less setups.");
  }

  // ── Phase 3: dlopen every signed dylib ──
  for (int i = 0; i < dylib_count; i++) {
    NSString *fullPath =
        [basePath stringByAppendingPathComponent:receivedNames[i]];
    const char *path = [fullPath UTF8String];
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      debug_print(@"[!] Failed to load %s: %s", path, dlerror());
      exit(1);
    }
    objs[i] = h;
  }
  debug_print(@"[DylibLoader] Finished loading");
  /*    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,
     0), ^{ debug_print(@"[DylibLoader] Finished loading - now im gonna wait");
          char monitor[1];
          while (recv(sock, monitor, 1, 0) > 0) { }
          debug_print(@"[*] Connection lost. Killing app.");
          exit(0);
      });*/
}

__attribute__((constructor)) static void init() {
  INIT_LOGGER("FuckLoader");
  start_bridge_listener();
}
