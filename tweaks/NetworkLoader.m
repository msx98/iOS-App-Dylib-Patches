#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sys/socket.h>
#import <unistd.h>

#import <objc/message.h>
#import <objc/runtime.h>

#import "../lib/utils/utils.m"

// ── All LiveContainer symbols resolved purely at runtime ──
// No linker references — uses NSClassFromString / dlsym / objc_msgSend.
// LCUtils is NOT available in the guest process, so we call ZSigner directly.

// ── Sign all dylibs in a folder via ZSign (same pipeline as LCUtils) ──
//   1. Copy dylibs into a temporary .app wrapper
//   2. Load ZSign.dylib, get provisioning profile + cert from the host
//   3. Call [ZSigner signWithAppPath:prov:key:pass:completionHandler:]
//   4. Move signed dylibs back, clean up

static BOOL signReceivedTweaks(NSArray<NSString *> *fileNames) {
  // Resolve LCSharedUtils (available in guest process)
  Class LCSharedUtils = NSClassFromString(@"LCSharedUtils");
  if (!LCSharedUtils) {
    debug_print(@"LCSharedUtils not found — not running inside "
                @"LiveContainer?");
    return NO;
  }
  debug_print(@"LCSharedUtils found: %p", LCSharedUtils);

  // Check certificate password: +[LCSharedUtils certificatePassword]
  SEL certPassSel = NSSelectorFromString(@"certificatePassword");
  NSString *certPass =
      ((id(*)(id, SEL))objc_msgSend)(LCSharedUtils, certPassSel);
  if (!certPass) {
    debug_print(@"No signing certificate configured, skipping sign.");
    return YES;
  }

  // Get certificate data from UserDefaults (same as +[LCUtils certificateData])
  SEL appGroupIDSel = NSSelectorFromString(@"appGroupID");
  NSString *appGroupID =
      ((id(*)(id, SEL))objc_msgSend)(LCSharedUtils, appGroupIDSel);
  NSUserDefaults *groupDefaults =
      appGroupID ? [[NSUserDefaults alloc] initWithSuiteName:appGroupID]
                 : [NSUserDefaults standardUserDefaults];
  NSData *certData = [groupDefaults objectForKey:@"LCCertificateData"];
  if (!certData) {
    debug_print(@"No LCCertificateData found in UserDefaults.");
    return NO;
  } else {
    debug_print(@"Certificate data loaded: %lu bytes",
                (unsigned long)certData.length);
  }

  NSBundle *hostBundle = getActualHostBundle();
  if (!hostBundle) {
    debug_print(@"Host bundle not found, cannot proceed with signing.");
    return NO;
  }

  // Get embedded.mobileprovision from the host bundle
  NSURL *profileURL = [hostBundle URLForResource:@"embedded"
                                   withExtension:@"mobileprovision"];
  NSData *profileData =
      profileURL ? [NSData dataWithContentsOfURL:profileURL] : nil;
  if (!profileData) {
    debug_print(@"embedded.mobileprovision not found at %@",
                hostBundle.bundlePath);
    return NO;
  }

  // Load OpenSSL.framework then ZSign.dylib from the host bundle's Frameworks
  NSString *frameworksDir =
      [hostBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
  debug_print(@"Frameworks directory: %@", frameworksDir);

  // OpenSSL must be loaded first — ZSign.dylib links against
  // @rpath/OpenSSL.framework/OpenSSL
  static BOOL opensslLoaded = NO;
  if (!opensslLoaded) {
    NSString *opensslPath = [frameworksDir
        stringByAppendingPathComponent:@"OpenSSL.framework/OpenSSL"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:opensslPath]) {
      debug_print(@"OpenSSL not found at: %@", opensslPath);
      return NO;
    }
    void *sslHandle = dlopen(opensslPath.UTF8String, RTLD_GLOBAL);
    if (!sslHandle) {
      debug_print(@"Failed to load OpenSSL: %s", dlerror());
      return NO;
    }
    opensslLoaded = YES;
    debug_print(@"OpenSSL loaded successfully.");
  }

  NSString *zsignDylibPath =
      [frameworksDir stringByAppendingPathComponent:@"ZSign.dylib"];
  debug_print(@"ZSign.dylib path: %@", zsignDylibPath);

  static BOOL zsignLoaded = NO;
  void *zsignHandle = nil;
  if (!zsignLoaded) {
    zsignHandle = dlopen(zsignDylibPath.UTF8String, RTLD_GLOBAL);
    if (!zsignHandle) {
      debug_print(@"Failed to load ZSign.dylib: %s", dlerror());
      return NO;
    }
    zsignLoaded = YES;
    debug_print(@"ZSign.dylib loaded successfully.");
  } else {
    debug_print(@"ZSign.dylib already loaded, skipping dlopen.");
  }
  debug_print(@"About to call NSClassFromString(@\"ZSigner\")…");
  Class ZSigner = NSClassFromString(@"ZSigner");

  if (!ZSigner) {
    debug_print(@"ZSigner class not found after loading ZSign.dylib.");
    return NO;
  } else {
    debug_print(@"ZSign class found: %p", ZSigner);
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *tmpAppDir =
      [NSTemporaryDirectory() stringByAppendingPathComponent:@"TweakTmp.app"];

  // Clean slate
  [fm removeItemAtPath:tmpAppDir error:nil];
  [fm createDirectoryAtPath:tmpAppDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  // ZSign expects an Info.plist + a dummy executable in the .app
  NSString *tmpExecPath =
      [tmpAppDir stringByAppendingPathComponent:@"LiveContainer.tmp"];
  NSString *tmpInfoPath =
      [tmpAppDir stringByAppendingPathComponent:@"Info.plist"];
  NSMutableDictionary *info = [hostBundle.infoDictionary mutableCopy];
  info[@"CFBundleExecutable"] = @"LiveContainer.tmp";
  [info writeToFile:tmpInfoPath atomically:YES];
  [fm copyItemAtPath:hostBundle.executablePath toPath:tmpExecPath error:nil];

  // Copy each dylib into the .app
  NSMutableArray<NSString *> *tmpPaths = [NSMutableArray array];
  for (NSString *src in fileNames) {
    NSString *name = [src lastPathComponent];
    NSString *dst = [tmpAppDir stringByAppendingPathComponent:name];
    NSError *copyErr = nil;
    [fm copyItemAtPath:src toPath:dst error:&copyErr];
    if (copyErr) {
      debug_print(@"Copy to tmp failed: %@", copyErr);
      continue;
    }
    [tmpPaths addObject:dst];
  }

  if (tmpPaths.count == 0) {
    [fm removeItemAtPath:tmpAppDir error:nil];
    return YES;
  }

  // Fix up ARM64e slices if present
  void (*patchFn)(NSURL *) = (void (*)(NSURL *))dlsym(
      RTLD_DEFAULT, "LCPatchAppBundleFixupARM64eSlice");
  if (patchFn) {
    patchFn([NSURL fileURLWithPath:tmpAppDir]);
  } else {
    debug_print(@"LCPatchAppBundleFixupARM64eSlice not found, skipping.");
  }

  // Sign via [ZSigner signWithAppPath:prov:key:pass:completionHandler:]
  __block BOOL signSuccess = NO;
  __block NSError *signError = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  SEL signSel =
      NSSelectorFromString(@"signWithAppPath:prov:key:pass:completionHandler:");
  void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
    signSuccess = success;
    signError = error;
    dispatch_semaphore_signal(sema);
  };

  debug_print(@"Calling ZSigner to sign %@…", tmpAppDir);
  NSProgress *progress = ((
      NSProgress * (*)(id, SEL, NSString *, NSData *, NSData *, NSString *, id))
                              objc_msgSend)(
      ZSigner, signSel, tmpAppDir, profileData, certData, certPass, completion);

  if (!progress) {
    debug_print(@"ZSigner signWithAppPath returned nil.");
    [fm removeItemAtPath:tmpAppDir error:nil];
    return NO;
  }
  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

  if (!signSuccess) {
    debug_print(@"Signing failed: %@", signError);
    [fm removeItemAtPath:tmpAppDir error:nil];
    return NO;
  } else {
    debug_print(@"Signing succeeded.");
  }

  // Move signed dylibs back, overwriting originals
  for (int i = 0; i < tmpPaths.count; i++) {
    NSString *tmpPath = tmpPaths[i];
    NSString *name = [tmpPath lastPathComponent];
    NSString *dstPath = fileNames[i];

    // Log sizes before move
    NSDictionary *srcAttrs = [fm attributesOfItemAtPath:tmpPath error:nil];
    NSDictionary *dstAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
    debug_print(@"%@: tmp size=%llu, dst size=%llu, attempting "
                @"to remove at %@",
                name, [srcAttrs fileSize], [dstAttrs fileSize], dstPath);

    [fm removeItemAtPath:dstPath error:nil];
    NSError *moveErr = nil;
    debug_print(@"Moving %@ back to %@…", name, dstPath);
    if (![fm moveItemAtPath:tmpPath toPath:dstPath error:&moveErr]) {
      debug_print(@"Move back failed for %@: %@", name, moveErr);
    } else {
      NSDictionary *finalAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
      debug_print(@"Moved %@ back, final size=%llu", name,
                  [finalAttrs fileSize]);
    }
  }

  // Cleanup temp .app leftovers (_CodeSignature, provisioning profile, dummy
  // exec, etc.)
  [fm removeItemAtPath:tmpAppDir error:nil];

  debug_print(@"All %lu tweaks signed successfully.",
              (unsigned long)tmpPaths.count);
  return YES;
}

static BOOL recv_exact(int sock, void *buf, size_t len) {
  size_t received = 0;
  while (received < len) {
    ssize_t r = recv(sock, (char *)buf + received, len - received, 0);
    if (r <= 0)
      return NO;
    received += r;
  }
  return YES;
}

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

static void init() {
  int sock = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  addr.sin_family = AF_INET;
  addr.sin_port = htons(8887);
  NSLog(@"[NetworkLoader] Connecting to controller 2 at %s:8887…",
        CONTROLLER_IP.UTF8String);
  os_log(OS_LOG_DEFAULT, "[NetworkLoader] Controller IP 2: %{public}s",
         CONTROLLER_IP.UTF8String);
  getControllerIP();
  NSLog(@"[NetworkLoader] Connecting to controller 2 at %s:8887…",
        CONTROLLER_IP.UTF8String);
  os_log(OS_LOG_DEFAULT, "[NetworkLoader] Controller IP 2: %{public}s",
         CONTROLLER_IP.UTF8String);
  // NSLog(@"[NetworkLoader] Controller IP: %s", CONTROLLER_IP.UTF8String); //
  // shows controller IP as "private"

  NSLog(@"[NetworkLoader] Controller IP 3: %@",
        CONTROLLER_IP); // shows controller
  addr.sin_addr.s_addr = inet_addr(CONTROLLER_IP.UTF8String);

  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    exit(1);

  // Receive "READY"
  char junk[1024];
  recv(sock, junk, sizeof(junk), 0);

  // Receive manifest count
  uint32_t dylib_count = 0;
  recv_exact(sock, &dylib_count, 4);
  dylib_count = ntohl(dylib_count);
  debug_print(@"Manifest: %u dylibs", dylib_count);

  NSString *basePath = [getActualContainerPath()
      stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
  NSString *loadPath = [basePath stringByAppendingPathComponent:@"Load"];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:basePath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  [fm createDirectoryAtPath:loadPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  // ── Phase 1: Receive manifest (name + sha256 per file) ──
  NSMutableArray<NSString *> *allNames =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSString *> *allPaths =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSData *> *allHashes =
      [NSMutableArray arrayWithCapacity:dylib_count];

  for (uint32_t i = 0; i < dylib_count; i++) {
    uint32_t name_len = 0;
    recv_exact(sock, &name_len, 4);
    // name_len is little-endian ('<I') — no swap needed on LE arch
    char *name_buf = malloc(name_len + 1);
    recv_exact(sock, name_buf, name_len);
    name_buf[name_len] = '\0';

    uint8_t hash_bytes[32];
    recv_exact(sock, hash_bytes, 32);

    NSString *fileName = [NSString stringWithUTF8String:name_buf];
    free(name_buf);
    NSString *fullPath =
        [fileName isEqualToString:@"NetworkLoader.dylib"]
            ? [basePath stringByAppendingPathComponent:fileName]
            : [loadPath stringByAppendingPathComponent:fileName];

    [allNames addObject:fileName];
    [allPaths addObject:fullPath];
    [allHashes addObject:[NSData dataWithBytes:hash_bytes length:32]];
  }

  // Delete files in Load/ that are no longer in the manifest (+ their sidecars)
  NSArray<NSString *> *existing =
      [fm contentsOfDirectoryAtPath:loadPath error:nil] ?: @[];
  NSSet<NSString *> *manifestNames = [NSSet setWithArray:allNames];
  for (NSString *name in existing) {
    if ([name hasSuffix:@".sha256"])
      continue; // handled with their dylib
    if (![manifestNames containsObject:name]) {
      debug_print(@"Removing stale: %@", name);
      [fm removeItemAtPath:[loadPath stringByAppendingPathComponent:name]
                     error:nil];
      [fm removeItemAtPath:[loadPath
                               stringByAppendingPathComponent:
                                   [name stringByAppendingString:@".sha256"]]
                     error:nil];
    }
  }

  // Determine which files are missing or whose pre-signing hash has changed
  NSMutableArray<NSNumber *> *neededIndices = [NSMutableArray array];
  for (uint32_t i = 0; i < dylib_count; i++) {
    NSString *sidecar = [allPaths[i] stringByAppendingString:@".sha256"];
    NSData *stored = [NSData dataWithContentsOfFile:sidecar];
    if (!stored || ![stored isEqualToData:allHashes[i]]) {
      debug_print(@"%@: %@", allNames[i],
                  stored ? @"hash mismatch" : @"missing");
      [neededIndices addObject:@(i)];
    } else {
      debug_print(@"%@: up to date", allNames[i]);
    }
  }

  // Send needed indices to server
  uint32_t needed_count = htonl((uint32_t)neededIndices.count);
  send(sock, &needed_count, 4, 0);
  for (NSNumber *n in neededIndices) {
    uint32_t idx = htonl(n.unsignedIntValue);
    send(sock, &idx, 4, 0);
  }
  debug_print(@"Requesting %lu/%u files…", (unsigned long)neededIndices.count,
              dylib_count);

  // ── Phase 2: Receive only needed files ──
  NSMutableArray<NSString *> *receivedPaths = [NSMutableArray array];
  for (NSNumber *n in neededIndices) {
    uint32_t i = n.unsignedIntValue;
    const char *path = [allPaths[i] UTF8String];

    uint32_t data_len = 0;
    recv_exact(sock, &data_len, 4);
    data_len = ntohl(data_len);
    debug_print(@"#%u: receiving %@ (%u bytes)…", i, allNames[i], data_len);

    unlink(path);
    FILE *fp = fopen(path, "wb");
    if (!fp) {
      exit(1);
    }
    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"ERROR: Failed to receive %s", path);
      exit(1);
    }
    fclose(fp);
    // Persist the pre-signing hash so we can skip re-downloading on next run
    NSString *sidecar = [allPaths[i] stringByAppendingString:@".sha256"];
    [allHashes[i] writeToFile:sidecar atomically:YES];
    [receivedPaths addObject:allPaths[i]];
  }

  // ── Phase 3: Sign newly received tweaks ──
  if (receivedPaths.count > 0) {
    debug_print(@"Signing %lu tweaks…", (unsigned long)receivedPaths.count);
    if (!signReceivedTweaks(receivedPaths)) {
      debug_print(
          @"WARNING: Signing failed — dlopen may fail on JIT-less setups.");
    } else {
      debug_print(@"Signing succeeded.");
    }
  }

  // ── Phase 4: dlopen all tweaks ──
  debug_print(@"Loading %u tweaks…", dylib_count);
  for (uint32_t i = 0; i < dylib_count; i++) {
    if ([allNames[i] isEqualToString:@"NetworkLoader.dylib"]) {
      debug_print(@"Skipping self-reload");
      continue;
    }
    const char *path = [allPaths[i] UTF8String];
    debug_print(@"Loading %s…", path);
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      debug_print(@"[!] Failed to load %s: %s", path, dlerror());
      exit(1);
    }
    debug_print(@"Loaded %s successfully.", path);
  }
  debug_print(@"Finished loading");
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    debug_print(@"Waiting for kill ping…");
    char monitor[1];
    if (recv(sock, monitor, 1, 0) > 0) {
      debug_print(@"Received kill ping");
      abort();
    }
  });
}

INITIALIZE("NetworkLoader")
