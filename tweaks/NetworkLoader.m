#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <libkern/OSByteOrder.h>
#import <netinet/in.h>
#import <os/log.h>
#import <sqlite3.h>
#import <sys/socket.h>
#import <unistd.h>

#import <objc/message.h>
#import <objc/runtime.h>

#import "../lib/utils/utils.m"

// ── SQLite tweak registry ─────────────────────────────────────────────────
// Schema: PRIMARY KEY (basename, position), remotePath UNIQUE,
//         unsignedHash BLOB, updateTime INTEGER
//         local name = {basename}.{position}.{last8hexOfSha256}
static sqlite3 *g_db = NULL;

static void db_open(NSString *path) {
  if (sqlite3_open(path.UTF8String, &g_db) != SQLITE_OK) {
    debug_print(@"sqlite3_open failed: %s", sqlite3_errmsg(g_db));
    g_db = NULL;
    return;
  }
  const char *ddl = "CREATE TABLE IF NOT EXISTS tweaks ("
                    "  basename       TEXT    NOT NULL,"
                    "  position       INTEGER NOT NULL," // rank among rows with same basename; local name = {basename}.{position}.{last8hexOfSha256}
                    "  remotePath     TEXT    NOT NULL UNIQUE,"
                    "  unsignedHash   BLOB    NOT NULL,"
                    "  updateTime     INTEGER NOT NULL,"
                    "  PRIMARY KEY (basename, position)"
                    ")";
  char *err = NULL;
  if (sqlite3_exec(g_db, ddl, NULL, NULL, &err) != SQLITE_OK) {
    debug_print(@"CREATE TABLE failed: %s", err);
    sqlite3_free(err);
  }
}

// Local name format: "{basename}.{position}.{last8hexOfSha256}"
static NSString *makeLocalName(NSString *remotePath, int64_t position,
                               NSData *sha256) {
  const uint8_t *b = (const uint8_t *)sha256.bytes;
  NSString *tail = [NSString stringWithFormat:@"%02x%02x%02x%02x",
                    b[28], b[29], b[30], b[31]];
  NSString *base = [remotePath.lastPathComponent stringByDeletingPathExtension];
  return [NSString stringWithFormat:@"%@.%lld.%@", base, (long long)position,
                   tail];
}

// Returns the stored position for an existing row, or the next available rank
// for a new one (MAX(position)+1 among rows with the same basename).
static int64_t db_resolve_position(NSString *remotePath) {
  if (!g_db)
    return 1;
  sqlite3_stmt *st = NULL;
  sqlite3_prepare_v2(g_db,
                     "SELECT position FROM tweaks WHERE remotePath=? LIMIT 1",
                     -1, &st, NULL);
  sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
  int64_t pos = 0;
  if (sqlite3_step(st) == SQLITE_ROW)
    pos = sqlite3_column_int64(st, 0);
  sqlite3_finalize(st);
  if (pos > 0)
    return pos;
  // New row: next rank for this basename.
  NSString *base = [remotePath.lastPathComponent stringByDeletingPathExtension];
  sqlite3_prepare_v2(
      g_db, "SELECT COALESCE(MAX(position), 0) + 1 FROM tweaks WHERE basename=?",
      -1, &st, NULL);
  sqlite3_bind_text(st, 1, base.UTF8String, -1, SQLITE_TRANSIENT);
  pos = 1;
  if (sqlite3_step(st) == SQLITE_ROW)
    pos = sqlite3_column_int64(st, 0);
  sqlite3_finalize(st);
  return pos;
}

// Reconstruct the local name for a stored row, or nil if not found.
static NSString *db_lookup_localName(NSString *remotePath) {
  if (!g_db)
    return nil;
  sqlite3_stmt *st = NULL;
  sqlite3_prepare_v2(
      g_db,
      "SELECT basename, position, unsignedHash FROM tweaks WHERE remotePath=? LIMIT 1",
      -1, &st, NULL);
  sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
  NSString *localName = nil;
  if (sqlite3_step(st) == SQLITE_ROW) {
    const char *base = (const char *)sqlite3_column_text(st, 0);
    int64_t pos = sqlite3_column_int64(st, 1);
    const uint8_t *b = (const uint8_t *)sqlite3_column_blob(st, 2);
    int len = sqlite3_column_bytes(st, 2);
    if (base && b && len >= 32) {
      NSString *tail = [NSString stringWithFormat:@"%02x%02x%02x%02x",
                        b[28], b[29], b[30], b[31]];
      localName = [NSString stringWithFormat:@"%s.%lld.%@", base,
                             (long long)pos, tail];
    }
  }
  sqlite3_finalize(st);
  return localName;
}

static void db_upsert(NSString *remotePath, NSData *unsignedHash,
                      int64_t updateTime) {
  if (!g_db)
    return;
  NSString *basename =
      [remotePath.lastPathComponent stringByDeletingPathExtension];
  sqlite3_stmt *st = NULL;
  // position = rank among existing rows with the same basename (1-based).
  // ON CONFLICT: preserve position, only refresh unsignedHash and updateTime.
  sqlite3_prepare_v2(
      g_db,
      "INSERT INTO tweaks (remotePath, basename, position, unsignedHash, updateTime)"
      " VALUES (?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM tweaks WHERE basename = ?), ?, ?)"
      " ON CONFLICT(remotePath) DO UPDATE SET"
      "   unsignedHash = excluded.unsignedHash,"
      "   updateTime   = excluded.updateTime",
      -1, &st, NULL);
  sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 2, basename.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 3, basename.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_blob(st, 4, unsignedHash.bytes, (int)unsignedHash.length, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 5, updateTime);
  sqlite3_step(st);
  sqlite3_finalize(st);
}

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
  getControllerIP();
  NSLog(@"[NetworkLoader] Controller IP: %@", CONTROLLER_IP);
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

  NSString *containerPath = getActualContainerPath();
  NSString *tweaksDir =
      [containerPath stringByAppendingPathComponent:@"Documents/NetworkTweaks"];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:tweaksDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  db_open([tweaksDir stringByAppendingPathComponent:@"tweaks.db"]);

  // ── Phase 1: Receive manifest (name + sha256 + mtime per file) ──
  NSMutableArray<NSString *> *allNames =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSData *> *allHashes =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSNumber *> *allRemoteTimes =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSString *> *allPaths =
      [NSMutableArray arrayWithCapacity:dylib_count];
  // "{BaseName}.{last8hexOfSha256}" — deterministic from name+hash
  NSMutableArray<NSString *> *allUUIDs =
      [NSMutableArray arrayWithCapacity:dylib_count];

  NSMutableArray<NSNumber *> *neededIndices = [NSMutableArray array];
  NSUInteger networkLoaderIdx = NSNotFound;

  for (uint32_t i = 0; i < dylib_count; i++) {
    uint32_t name_len = 0;
    recv_exact(sock, &name_len, 4);
    char *name_buf = malloc(name_len + 1);
    recv_exact(sock, name_buf, name_len);
    name_buf[name_len] = '\0';
    NSString *fileName = [NSString stringWithUTF8String:name_buf];
    free(name_buf);

    uint8_t hash_bytes[32];
    recv_exact(sock, hash_bytes, 32);
    NSData *hash = [NSData dataWithBytes:hash_bytes length:32];

    uint64_t remoteTs_net = 0;
    recv_exact(sock, &remoteTs_net, 8);
    int64_t remoteTs = (int64_t)OSSwapBigToHostInt64(remoteTs_net);

    [allNames addObject:fileName];
    [allHashes addObject:hash];
    [allRemoteTimes addObject:@(remoteTs)];

    if ([fileName isEqualToString:@"NetworkLoader.dylib"])
      networkLoaderIdx = i;

    int64_t position = db_resolve_position(fileName);
    NSString *uuid = makeLocalName(fileName, position, hash);
    [allUUIDs addObject:uuid];

    NSString *diskPath = [tweaksDir
        stringByAppendingPathComponent:[uuid stringByAppendingString:@".dylib"]];
    [allPaths addObject:diskPath];

    // If this remotePath was previously stored under a different localName, remove the old file.
    NSString *oldLocalName = db_lookup_localName(fileName);
    NSString *localName = [uuid stringByAppendingString:@".dylib"];
    if (oldLocalName && ![oldLocalName isEqualToString:localName]) {
      NSString *oldPath = [tweaksDir stringByAppendingPathComponent:oldLocalName];
      debug_print(@"%@: hash changed, removing old version %@", fileName, oldLocalName);
      [fm removeItemAtPath:oldPath error:nil];
    }

    if (![fm fileExistsAtPath:diskPath]) {
      debug_print(@"%@: missing", fileName);
      [neededIndices addObject:@(i)];
    } else {
      debug_print(@"%@: up to date", fileName);
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
    if (!fp)
      exit(1);
    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"ERROR: Failed to receive %s", path);
      exit(1);
    }
    fclose(fp);

    db_upsert(allNames[i], allHashes[i], [allRemoteTimes[i] longLongValue]);
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

  // ── Phase 3.5: Copy NetworkLoader to LiveTweaks/ for next-boot pickup ──
  if (networkLoaderIdx != NSNotFound) {
    NSString *liveTweaks = [containerPath
        stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
    [fm createDirectoryAtPath:liveTweaks
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
    NSString *dst =
        [liveTweaks stringByAppendingPathComponent:@"NetworkLoader.dylib"];
    [fm removeItemAtPath:dst error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:allPaths[networkLoaderIdx] toPath:dst
                     error:&copyErr]) {
      debug_print(@"Failed to copy NetworkLoader to LiveTweaks: %@", copyErr);
    } else {
      debug_print(@"NetworkLoader ready in LiveTweaks.");
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
