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


#import <CommonCrypto/CommonDigest.h>

static NSString *sha256ForFile(NSString *path) {
    FILE *fp = fopen(path.UTF8String, "rb");
    if (!fp) return nil;

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX sha256;
    CC_SHA256_Init(&sha256);

    const int bufSize = 32768;
    unsigned char *buffer = malloc(bufSize);
    size_t bytesRead = 0;
    while ((bytesRead = fread(buffer, 1, bufSize, fp)) > 0) {
        CC_SHA256_Update(&sha256, buffer, (CC_LONG)bytesRead);
    }
    free(buffer);
    fclose(fp);

    CC_SHA256_Final(hash, &sha256);
    NSMutableString *hashString = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat:@"%02x", hash[i]];
    }
    return hashString;
}


static BOOL signReceivedTweaks(NSString *tweakDir,
                               NSArray<NSString *> *fileNames) {
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

  // Get LiveContainer's original bundle via the lcMainBundle global
  // (set in LCBootstrap.m before mainBundle is swizzled to the guest app)
  NSBundle **lcMainBundlePtr = (NSBundle **)dlsym(RTLD_DEFAULT, "lcMainBundle");
  debug_print(@"lcMainBundle pointer: %p", lcMainBundlePtr);
  NSBundle *hostBundle = lcMainBundlePtr ? *lcMainBundlePtr : nil;
  debug_print(@"hostBundle pointer 1: %p", hostBundle);
  if (!hostBundle) {
    debug_print(@"lcMainBundle not found via dlsym.");
    return NO;
  }

  // lcMainBundle may point to LiveProcess.appex — walk up to the main .app
  // LiveProcess.appex -> PlugIns/ -> LiveContainer.app
  NSString *bundlePath = hostBundle.bundlePath;
  if ([bundlePath.pathExtension isEqualToString:@"appex"]) {
    NSString *mainAppPath = [[bundlePath stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent];
    NSBundle *mainAppBundle = [NSBundle bundleWithPath:mainAppPath];
    if (mainAppBundle) {
      hostBundle = mainAppBundle;
    }
  }
  debug_print(@"Host bundle path: %@", hostBundle.bundlePath);

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
    debug_print(@"OpenSSL path (I will check): %@", opensslPath);
    // check if file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:opensslPath]) {
      debug_print(@"OpenSSL not found at expected path: %@", opensslPath);
      return NO;
    } else {
      debug_print(@"OpenSSL found at expected path: %@", opensslPath);
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
  for (int i=0; i < tmpPaths.count; i++) {
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

static void init() {
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
  debug_print(@"Count 1: %d", dylib_count);
  dylib_count = ntohl(dylib_count);
  debug_print(@"Count 2: %d", dylib_count);

  NSString *basePath = [getActualContainerPath() stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
  [[NSFileManager defaultManager] createDirectoryAtPath:basePath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  void **objs = malloc(sizeof(void *) * dylib_count);
  NSMutableArray<NSString *> *receivedNames =
      [NSMutableArray arrayWithCapacity:dylib_count];
    NSMutableArray<NSString *> *receivedPaths =
      [NSMutableArray arrayWithCapacity:dylib_count];
    
  NSString *nonLoaderPath = [basePath stringByAppendingPathComponent:@"Load"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:nonLoaderPath]) {
    debug_print(@"Cleaning up existing Load directory at path: %@", nonLoaderPath);
    [[NSFileManager defaultManager] removeItemAtPath:nonLoaderPath error:nil];
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:nonLoaderPath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];

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
    NSString *fullPath = nil;
    if (![fileName isEqualToString:@"NetworkLoader.dylib"]) {
      fullPath = [[basePath stringByAppendingPathComponent:@"Load"] stringByAppendingPathComponent:fileName];
    } else {
      fullPath = [basePath stringByAppendingPathComponent:fileName];
    }
    [receivedPaths addObject:fullPath];
    const char *path = [fullPath UTF8String];
    
    debug_print(@"#%d needs to recva %d into %s", i, data_len, path);

    // Clean start
    unlink(path);

    FILE *fp = fopen(path, "wb");
    if (!fp) {
      exit(1);
    }

    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"ERROR: Cannot recv %s.", path);
      exit(1);
    }
    fclose(fp);
    [receivedNames addObject:fileName];
    free(name_buf);
  }

  // ── Phase 2: Sign all received tweaks via LiveContainer's ZSign ──
  debug_print(@"Signing %lu received tweaks…",
              (unsigned long)receivedNames.count);
  if (!signReceivedTweaks(basePath, receivedPaths)) {
    debug_print(@"WARNING: Signing failed — dlopen may fail on "
                @"JIT-less setups.");
  } else {
    debug_print(@"Signing succeeded for all tweaks.");
  }

  debug_print(@"About to load %d tweaks, %d…", (int)receivedNames.count,
              dylib_count);

  // ── Phase 3: dlopen every signed dylib ──
  for (int i = 0; i < dylib_count; i++) {
    if ([receivedNames[i] isEqualToString:@"NetworkLoader.dylib"]) {
      debug_print(@"Skipping reloading myself");
      continue;
    }
    debug_print(@"%d: Loading tweaka %@…", i, receivedNames[i]);
    NSString *fullPath = receivedPaths[i];
    const char *path = [fullPath UTF8String];
    debug_print(@"Loading %s…", path);
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      debug_print(@"[!] Failed to load %s: %s", path, dlerror());
      exit(1);
    }
    objs[i] = h;
    debug_print(@"Loaded %s successfully.", path);
  }
  debug_print(@"Finished loading");
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,
     0), ^{ debug_print(@"Finished loading - now im gonna wait");
          char monitor[1];
          if (recv(sock, monitor, 1, 0) > 0) {
            debug_print(@"Received kill ping");
            abort();
          }
      });
}


INITIALIZE("NetworkLoader")
