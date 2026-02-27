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
  if (fileNames.count == 0) {
    debug_print(@"No tweaks to sign, skipping.");
    return YES;
  } else {
    debug_print(@"Tweaks to sign: %@", fileNames);
  }
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
                    "  remotePath     TEXT PRIMARY KEY,"
                    "  basename       TEXT NOT NULL,"
                    "  position       INTEGER NOT NULL," // rank among rows with same basename; local name = {basename}.{position}.{last8hexOfSha256}
                    "  unsignedHash   BLOB NOT NULL,"
                    "  updateTime     INTEGER NOT NULL"
                    ")";
  char *err = NULL;
  if (sqlite3_exec(g_db, ddl, NULL, NULL, &err) != SQLITE_OK) {
    debug_print(@"CREATE TABLE failed: %s", err);
    sqlite3_free(err);
  }
}

static NSString *derive_localName(NSString *remotePath, int position, NSData *unsignedHash) {
  NSString *baseName = [remotePath.lastPathComponent stringByDeletingPathExtension];
  const unsigned char *hashBytes = unsignedHash.bytes;
  return [NSString stringWithFormat:@"%@.%d.%02x%02x%02x%02x.dylib",
          baseName, position,
          hashBytes[28], hashBytes[29], hashBytes[30], hashBytes[31]];
}

static NSString *db_lookup_localName(NSString *remotePath) {
  // Format: {basename}.{position}.{last8hexOfSha256}.dylib
  if (!g_db)
    return nil;
  NSString *baseName = [remotePath.lastPathComponent stringByDeletingPathExtension];
  sqlite3_stmt *st = NULL;
  sqlite3_prepare_v2(g_db,
                     "SELECT position, unsignedHash FROM tweaks WHERE remotePath=? LIMIT 1",
                     -1, &st, NULL);
  sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
  NSString *localName = nil;
  if (sqlite3_step(st) == SQLITE_ROW) {
    int position = sqlite3_column_int(st, 0);
    const void *hashBytes = sqlite3_column_blob(st, 1);
    int hashLen = sqlite3_column_bytes(st, 1);
    if (hashBytes && hashLen == 32) {
      NSData *unsignedHash = [NSData dataWithBytes:hashBytes length:hashLen];
      localName = derive_localName(remotePath, position, unsignedHash);
    }
  }
  sqlite3_finalize(st);
  return localName;
}

static int db_upsert(NSString *remotePath, NSData *unsignedHash, int64_t updateTime) {
  if (!g_db)
    return -1;
  NSString *basename =
      [remotePath.lastPathComponent stringByDeletingPathExtension];
  debug_print(@"Upserting into DB: remotePath=%s, baseName=%s", remotePath.UTF8String, basename.UTF8String);
  sqlite3_stmt *st = NULL;
  // position = rank among existing rows with the same basename (1-based).
  // ON CONFLICT: preserve position, only refresh unsignedHash and updateTime.
  sqlite3_prepare_v2(
      g_db,
      "INSERT INTO tweaks (remotePath, basename, position, unsignedHash, updateTime)"
      " VALUES (?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM tweaks WHERE basename=?), ?, ?)"
      " ON CONFLICT(remotePath) DO UPDATE SET"
      "   unsignedHash = excluded.unsignedHash,"
      "   updateTime   = excluded.updateTime"
      " RETURNING position",
      -1, &st, NULL);
  sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 2, basename.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 3, basename.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_blob(st, 4, unsignedHash.bytes, (int)unsignedHash.length, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 5, updateTime);
  int position = -1;
  if (sqlite3_step(st) == SQLITE_ROW) {
    position = sqlite3_column_int(st, 0);
    debug_print(@"DB upsert successful: position=%d", position);
  } else {
    debug_print(@"DB upsert failed: %s", sqlite3_errmsg(g_db));
  }
  sqlite3_finalize(st);
  return position;
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
  NSString *downloadsDir = [tweaksDir stringByAppendingPathComponent:@".Downloads"];
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:downloadsDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  db_open([tweaksDir stringByAppendingPathComponent:@"tweaks.db"]);

  // ── Phase 1: Receive manifest (name + sha256 + mtime per file) ──
  NSMutableArray<NSString *> *allRemotePaths =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSNumber *> *allPositions =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSData *> *allHashes =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSNumber *> *allRemoteTimes =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSString *> *allDownloadPaths =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSString *> *allLocalNames =
      [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableArray<NSString *> *allOldLocalNames =
      [NSMutableArray arrayWithCapacity:dylib_count];
  // "{BaseName}.{last8hexOfSha256}" — deterministic from name+hash
  NSMutableArray<NSString *> *allUUIDs =
      [NSMutableArray arrayWithCapacity:dylib_count];

  NSMutableSet<NSString *> *uniqueRemotePaths = [NSMutableSet setWithCapacity:dylib_count];
  NSMutableArray<NSNumber *> *neededIndices = [NSMutableArray array];
  NSUInteger networkLoaderIdx = NSNotFound;

  for (uint32_t i = 0; i < dylib_count; i++) {
    BOOL needsDownload = NO;
    uint32_t name_len = 0;
    recv_exact(sock, &name_len, 4);
    char *name_buf = malloc(name_len + 1);
    recv_exact(sock, name_buf, name_len);
    name_buf[name_len] = '\0';
    NSString *remotePath = [NSString stringWithUTF8String:name_buf];
    free(name_buf);
    NSString *baseName = [remotePath.lastPathComponent stringByDeletingPathExtension];

    uint8_t hash_bytes[32];
    recv_exact(sock, hash_bytes, 32);
    NSData *hash = [NSData dataWithBytes:hash_bytes length:32];

    uint64_t remoteTs_net = 0;
    recv_exact(sock, &remoteTs_net, 8);
    int64_t remoteTs = (int64_t)OSSwapBigToHostInt64(remoteTs_net);

    [allRemotePaths addObject:remotePath];
    [allHashes addObject:hash];
    [allRemoteTimes addObject:@(remoteTs)];

    if ([baseName isEqualToString:@"NetworkLoader"])
      networkLoaderIdx = i;
    
    // Get position and localName from DB, derive expected local filename
    int position = -1;
    int64_t oldRemoteTs = 0;
    sqlite3_stmt *st = NULL;
    sqlite3_prepare_v2(g_db,
                      "SELECT position, unsignedHash, updateTime FROM tweaks WHERE remotePath=? LIMIT 1",
                      -1, &st, NULL);
    sqlite3_bind_text(st, 1, remotePath.UTF8String, -1, SQLITE_TRANSIENT);
    NSString *oldLocalName = nil;
    NSData *oldUnsignedHash = nil;
    if (sqlite3_step(st) == SQLITE_ROW) {
      position = sqlite3_column_int(st, 0);
      const void *hashBytes = sqlite3_column_blob(st, 1);
      int hashLen = sqlite3_column_bytes(st, 1);
      if (hashBytes && hashLen == 32) {
        oldUnsignedHash = [NSData dataWithBytes:hashBytes length:hashLen];
        oldLocalName = derive_localName(remotePath, position, oldUnsignedHash);
        if (![oldUnsignedHash isEqualToData:hash]) {
          debug_print(@"%@: hash changed", remotePath);
          needsDownload = YES;
        }
      }
      // compare update time
      oldRemoteTs = sqlite3_column_int64(st, 2);
      if (oldRemoteTs != remoteTs) {
        debug_print(@"%@: remote timestamp changed (old: %lld, new: %lld)", remotePath, oldRemoteTs, remoteTs);
        needsDownload = YES;
      }
    } else {
      debug_print(@"%@: new entry, no existing local name", remotePath);
      oldLocalName = @"";
      needsDownload = YES;
    }
    sqlite3_finalize(st);

if ([uniqueRemotePaths containsObject:remotePath]) {
      debug_print(@"WARNING: Duplicate remotePath in manifest: %@, index %u", remotePath, i);
      needsDownload = NO;
    } else {
      [uniqueRemotePaths addObject:remotePath];
    }

    NSString *localName = derive_localName(remotePath, position, hash);
    NSString *downloadPath = nil;
    if (needsDownload) {
      debug_print(@"%@: marked for download", remotePath);
      [neededIndices addObject:@(i)];
      downloadPath = [downloadsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%u.dylib", i]];
    } else {
      debug_print(@"%@: up to date, no download needed", remotePath);
      downloadPath = [tweaksDir stringByAppendingPathComponent:localName];
    }

    debug_print(@"%@: local name = %@, old = %@, position = %d, download path = %@", remotePath, localName, oldLocalName, position, downloadPath);

    [allLocalNames addObject:localName];
    [allOldLocalNames addObject:oldLocalName];
    [allPositions addObject:@(position)];
    [allDownloadPaths addObject:downloadPath];
  }

  // Send needed indices to server
  uint32_t needed_count = htonl((uint32_t)neededIndices.count);
  send(sock, &needed_count, 4, 0);
  for (NSNumber *n in neededIndices) {
    uint32_t idx = htonl(n.unsignedIntValue);
    send(sock, &idx, 4, 0);
  }
  debug_print(@"Requesting %lu/%u files…", (unsigned long)neededIndices.count, dylib_count);

  // ── Phase 2: Receive only needed files ──
  NSMutableArray<NSString *> *receivedPaths = [NSMutableArray array];
  for (NSNumber *n in neededIndices) {
    uint32_t i = n.unsignedIntValue;
    uint32_t data_len = 0;
    recv_exact(sock, &data_len, 4);
    data_len = ntohl(data_len);
    debug_print(@"#%u: receiving %@ (%u bytes)…", i, allRemotePaths[i], data_len);

    FILE *fp = fopen([allDownloadPaths[i] UTF8String], "wb");
    if (!fp)
      exit(1);
    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"ERROR: Failed to receive %@", allDownloadPaths[i]);
      exit(1);
    }
    fclose(fp);
    [receivedPaths addObject:allDownloadPaths[i]];
  }

  if (receivedPaths.count != neededIndices.count) {
    debug_print(@"ERROR: Expected to receive %lu files but got %lu",
                (unsigned long)neededIndices.count, (unsigned long)receivedPaths.count);
    exit(1);
  }

  if (!signReceivedTweaks(receivedPaths)) {
    debug_print(@"ERROR: Failed to sign received tweaks");
    exit(1);
  }

  // ── Phase 3.5: Copy NetworkLoader to LiveTweaks/ for next-boot pickup ──
  if (networkLoaderIdx != NSNotFound) {
    NSString *liveTweaks = [containerPath stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
    [fm createDirectoryAtPath:liveTweaks withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [liveTweaks stringByAppendingPathComponent:@"NetworkLoader.dylib"];
    [fm removeItemAtPath:dst error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:allDownloadPaths[networkLoaderIdx] toPath:dst error:&copyErr]) {
      debug_print(@"Failed to copy NetworkLoader to LiveTweaks: %@", copyErr);
    } else {
      debug_print(@"NetworkLoader ready in LiveTweaks.");
    }
  }

  BOOL loaderChanged = NO;

  for (NSNumber *n in neededIndices) {
    uint32_t i = n.unsignedIntValue;
    if (i == networkLoaderIdx) {
      loaderChanged = YES;
    }
    debug_print(@"Updating: %@", allDownloadPaths[i]);

    // Delete old local file
    if (allOldLocalNames[i]) {
      unlink([tweaksDir stringByAppendingPathComponent:allOldLocalNames[i]].UTF8String);
    }

    // Update DB with new position, hash, and timestamp
    int position = db_upsert(allRemotePaths[i], allHashes[i], [allRemoteTimes[i] longLongValue]);
    allPositions[i] = @(position);

    // Move received file into place (Downloads → Tweaks)
    NSString *finalName = derive_localName(allRemotePaths[i], position, allHashes[i]);
    NSString *finalPath = [tweaksDir stringByAppendingPathComponent:finalName];
    debug_print(@"Moving %@ to tweaks as %@…", allDownloadPaths[i], finalName);
    NSError *moveErr = nil;
    if (![fm moveItemAtPath:allDownloadPaths[i] toPath:finalPath error:&moveErr]) {
      debug_print(@"Move to tweaks failed: %@", moveErr);
      continue;
    }
    allDownloadPaths[i] = finalPath;
  }

  // Remove downloads dir
  [fm removeItemAtPath:downloadsDir error:nil];

  if ((networkLoaderIdx != NSNotFound) && loaderChanged) {
    debug_print(@"NetworkLoader was updated, switching to new version…");
    dlopen([allDownloadPaths[networkLoaderIdx] UTF8String], RTLD_NOW | RTLD_GLOBAL);
    return;
  }

  // ── Phase 4: dlopen all tweaks ──
  NSMutableSet<NSString *> *loadedPaths = [NSMutableSet set];
  debug_print(@"Loading %u tweaks…", dylib_count);
  for (uint32_t i = 0; i < dylib_count; i++) {
    if ([allRemotePaths[i] isEqualToString:@"NetworkLoader.dylib"]) {
      //debug_print(@"Skipping self-reload");
      continue;
    }
    if ([loadedPaths containsObject:allLocalNames[i]]) {
      debug_print(@"Already loaded %@, skipping dlopen", allLocalNames[i]);
      continue;
    }
    const char *path = [[tweaksDir stringByAppendingPathComponent:allLocalNames[i]]UTF8String];
    debug_print(@"Loading %s…", path);
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    [loadedPaths addObject:allLocalNames[i]];
    if (!h) {
      debug_print(@"[!] Failed to load %s: %s", path, dlerror());
      exit(1);
    }
    debug_print(@"Loaded %s successfully.", path);
  }
  debug_print(@"Finished loading");
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    debug_print(@"Waiting for kill ping or connection loss…");
    char monitor[1];
    recv(sock, monitor, 1, 0);
    abort();
  });
}

INITIALIZE("NetworkLoader")
