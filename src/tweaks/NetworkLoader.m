#include "logger.h"
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

#import "utils.h"

#define RTLD_MODE (RTLD_NOW | RTLD_GLOBAL)

// ── All LiveContainer symbols resolved purely at runtime ──
// No linker references — uses NSClassFromString / dlsym / objc_msgSend.
// LCUtils is NOT available in the guest process, so we call ZSigner directly.

// ── Sign all dylibs in a folder via ZSign (same pipeline as LCUtils) ──
//   1. Copy dylibs into a temporary .app wrapper
//   2. Load ZSign.dylib, get provisioning profile + cert from the host
//   3. Call [ZSigner signWithAppPath:prov:key:pass:completionHandler:]
//   4. Move signed dylibs back, clean up

// ── Per-entry manifest record ─────────────────────────────────────────────
@interface TweakEntry : NSObject
@property (nonatomic) uint32_t index;         // 0-based position in manifest
@property (nonatomic) NSString *remotePath;   // as sent by server (e.g. "MicSpoof.dylib")
@property (nonatomic) NSData *sha256;         // SHA-256 of the unsigned dylib
@property (nonatomic) int64_t remoteTs;       // source mtime from server
@property (nonatomic) int position;           // rank in DB (≥1); -1 if not yet inserted
@property (nonatomic) NSString *localName;    // {basename}.{position}.{last8hex}.dylib
@property (nonatomic) NSString *oldLocalName; // localName before this update (@"" if new)
@property (nonatomic) NSString *downloadPath; // staging path while receiving; final path after move
@property (nonatomic) BOOL needsDownload;
@end
@implementation TweakEntry
@end

// ── SQLite tweak registry ─────────────────────────────────────────────────
// Schema: PRIMARY KEY remotePath, position = rank among same basename,
//         unsignedHash BLOB, updateTime INTEGER
//         local name = {basename}.{position}.{last8hexOfSha256}
static sqlite3 *g_db = NULL;

static void db_open(NSString *path) {
  if (sqlite3_open(path.UTF8String, &g_db) != SQLITE_OK) {
    debug_print(@"sqlite3_open failed: %s", sqlite3_errmsg(g_db));
    g_db = NULL;
    return;
  }
  const char *create_tweaks_query =
      "CREATE TABLE IF NOT EXISTS tweaks ("
      "  remotePath     TEXT PRIMARY KEY,"
      "  basename       TEXT NOT NULL,"
      "  position       INTEGER NOT NULL," // rank among rows with same basename
      "  unsignedHash   BLOB NOT NULL,"
      "  updateTime     INTEGER NOT NULL"
      ")";
  char *err = NULL;
  if (sqlite3_exec(g_db, create_tweaks_query, NULL, NULL, &err) != SQLITE_OK) {
    debug_print(@"CREATE TABLE failed: %s", err);
    sqlite3_free(err);
  }
}

static NSString *derive_localName(NSString *remotePath, int position,
                                   NSData *unsignedHash) {
  NSString *baseName = [remotePath.lastPathComponent stringByDeletingPathExtension];
  const unsigned char *hashBytes = (unsigned char *)unsignedHash.bytes;
  return [NSString stringWithFormat:@"%@.%d.%02x%02x%02x%02x.dylib",
          baseName, position,
          hashBytes[28], hashBytes[29], hashBytes[30], hashBytes[31]];
}

static int db_upsert(NSString *remotePath, NSData *unsignedHash, int64_t updateTime) {
  if (!g_db)
    return -1;
  NSString *basename = [remotePath.lastPathComponent stringByDeletingPathExtension];
  debug_print(@"Upserting into DB: remotePath=%s, baseName=%s",
              remotePath.UTF8String, basename.UTF8String);
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

// ── Socket helpers ────────────────────────────────────────────────────────
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

static BOOL recv_to_file(int sock, FILE *fp, size_t total_len) {
  char buffer[8192];
  size_t received_so_far = 0;
  while (received_so_far < total_len) {
    size_t to_read = total_len - received_so_far;
    if (to_read > sizeof(buffer))
      to_read = sizeof(buffer);
    ssize_t r = recv(sock, buffer, to_read, 0);
    if (r <= 0)
      return NO;
    if (fwrite(buffer, 1, r, fp) != (size_t)r)
      return NO;
    received_so_far += r;
  }
  return YES;
}

// ── ZSign signing ─────────────────────────────────────────────────────────
static BOOL signReceivedTweaks(NSArray<NSString *> *fileNames) {
  if (fileNames.count == 0) {
    debug_print(@"No tweaks to sign, skipping.");
    return YES;
  } else {
    debug_print(@"Tweaks to sign: %@", fileNames);
  }

  Class LCSharedUtils = NSClassFromString(@"LCSharedUtils");
  if (!LCSharedUtils) {
    debug_print(@"LCSharedUtils not found — not running inside LiveContainer?");
    return NO;
  }
  debug_print(@"LCSharedUtils found: %p", LCSharedUtils);

  SEL certPassSel = NSSelectorFromString(@"certificatePassword");
  NSString *certPass =
      ((id(*)(id, SEL))objc_msgSend)(LCSharedUtils, certPassSel);
  if (!certPass) {
    debug_print(@"No signing certificate configured, skipping sign.");
    return YES;
  }

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
    debug_print(@"Certificate data loaded: %lu bytes", (unsigned long)certData.length);
  }

  NSBundle *hostBundle = getActualHostBundle();
  if (!hostBundle) {
    debug_print(@"Host bundle not found, cannot proceed with signing.");
    return NO;
  }

  NSURL *profileURL = [hostBundle URLForResource:@"embedded"
                                   withExtension:@"mobileprovision"];
  NSData *profileData = profileURL ? [NSData dataWithContentsOfURL:profileURL] : nil;
  if (!profileData) {
    debug_print(@"embedded.mobileprovision not found at %@", hostBundle.bundlePath);
    return NO;
  }

  // OpenSSL must be loaded first — ZSign.dylib links against @rpath/OpenSSL.framework/OpenSSL
  NSString *frameworksDir =
      [hostBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
  debug_print(@"Frameworks directory: %@", frameworksDir);

  static BOOL opensslLoaded = NO;
  if (!opensslLoaded) {
    NSString *opensslPath =
        [frameworksDir stringByAppendingPathComponent:@"OpenSSL.framework/OpenSSL"];
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
  if (!zsignLoaded) {
    void *zsignHandle = dlopen(zsignDylibPath.UTF8String, RTLD_GLOBAL);
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
  [fm removeItemAtPath:tmpAppDir error:nil];
  [fm createDirectoryAtPath:tmpAppDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  // ZSign expects an Info.plist + a dummy executable in the .app
  NSString *tmpExecPath = [tmpAppDir stringByAppendingPathComponent:@"LiveContainer.tmp"];
  NSString *tmpInfoPath = [tmpAppDir stringByAppendingPathComponent:@"Info.plist"];
  NSMutableDictionary *info = [hostBundle.infoDictionary mutableCopy];
  info[@"CFBundleExecutable"] = @"LiveContainer.tmp";
  [info writeToFile:tmpInfoPath atomically:YES];
  [fm copyItemAtPath:hostBundle.executablePath toPath:tmpExecPath error:nil];

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
  void (*patchFn)(NSURL *) =
      (void (*)(NSURL *))dlsym(RTLD_DEFAULT, "LCPatchAppBundleFixupARM64eSlice");
  if (patchFn) {
    patchFn([NSURL fileURLWithPath:tmpAppDir]);
  } else {
    debug_print(@"LCPatchAppBundleFixupARM64eSlice not found, skipping.");
  }

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
  NSProgress *progress = ((NSProgress * (*)(id, SEL, NSString *, NSData *, NSData *,
                                            NSString *, id))objc_msgSend)(
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
  for (NSUInteger i = 0; i < tmpPaths.count; i++) {
    NSString *tmpPath = tmpPaths[i];
    NSString *name = [tmpPath lastPathComponent];
    NSString *dstPath = fileNames[i];

    NSDictionary *srcAttrs = [fm attributesOfItemAtPath:tmpPath error:nil];
    NSDictionary *dstAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
    debug_print(@"%@: tmp size=%llu, dst size=%llu, attempting to remove at %@",
                name, [srcAttrs fileSize], [dstAttrs fileSize], dstPath);

    [fm removeItemAtPath:dstPath error:nil];
    NSError *moveErr = nil;
    debug_print(@"Moving %@ back to %@…", name, dstPath);
    if (![fm moveItemAtPath:tmpPath toPath:dstPath error:&moveErr]) {
      debug_print(@"Move back failed for %@: %@", name, moveErr);
    } else {
      NSDictionary *finalAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
      debug_print(@"Moved %@ back, final size=%llu", name, [finalAttrs fileSize]);
    }
  }

  [fm removeItemAtPath:tmpAppDir error:nil];
  debug_print(@"All %lu tweaks signed successfully.", (unsigned long)tmpPaths.count);
  return YES;
}

// Write Frida Gadget config then load it. Without a config the gadget pauses
// the process waiting for a debugger to attach.
// Uses listen mode + on_load:resume so the app runs normally; attach later with:
//   frida -H <device_ip>:27042 <bundle_id>
static void loadFridaGadget(NSString *gadgetPath) {
  void *h;
  char* cGadgetPath = strdup(gadgetPath.UTF8String);
  // Config must sit next to the dylib with the same stem, e.g.
  // Frida.1.abcd1234.config alongside Frida.1.abcd1234.dylib.
  NSString *configPath =
      [[gadgetPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"config"];

  NSString *configJSON =
      @"{\n"
       "  \"interaction\": {\n"
       "    \"type\": \"listen\",\n"
       "    \"address\": \"0.0.0.0\",\n"
       "    \"port\": 27042,\n"
       "    \"on_load\": \"resume\"\n"
       "  }\n"
       "}\n";

  NSError *writeErr = nil;
  if (![configJSON writeToFile:configPath atomically:YES
                      encoding:NSUTF8StringEncoding error:&writeErr]) {
    debug_print(@"Failed to write Frida config to %@: %@", configPath, writeErr);
    return;
  }
  debug_print(@"Frida config written to %@", configPath);

  debug_print(@"Loading Frida Gadget from %@ and breaking…", gadgetPath);
  sleep(3);
  __asm__ volatile("brk #0x539"); // breakpoint to catch dlopen in case of issues
  h = dlopen(cGadgetPath, RTLD_MODE);
  if (!h) {
    debug_print(@"Failed to load Frida Gadget: %s", dlerror());
    return;
  }
  debug_print(@"Frida Gadget loaded, listening on :27042");
}

// ── Phase 1: Connect + receive READY banner ───────────────────────────────
static int connectToServer(void) {
  int sock = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  addr.sin_family = AF_INET;
  addr.sin_port = htons(8887);
  getControllerIP();
  os_log(OS_LOG_DEFAULT, "[NetworkLoader] Controller IP: %{public}@", CONTROLLER_IP);
  addr.sin_addr.s_addr = inet_addr(CONTROLLER_IP.UTF8String);

  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    return -1;

  char junk[1024];
  recv(sock, junk, sizeof(junk), 0); // discard READY banner
  return sock;
}

// ── Phase 2: Receive manifest, determine what needs downloading ───────────
// outNetworkLoaderIdx is set to the index of the NetworkLoader entry, or NSNotFound.
static NSArray<TweakEntry *> *receiveManifest(int sock,
                                               NSString *tweaksDir,
                                               NSString *downloadsDir,
                                               NSUInteger *outNetworkLoaderIdx) {
  uint32_t dylib_count = 0;
  recv_exact(sock, &dylib_count, 4);
  dylib_count = ntohl(dylib_count);
  debug_print(@"Manifest: %u dylibs", dylib_count);

  NSMutableArray<TweakEntry *> *entries = [NSMutableArray arrayWithCapacity:dylib_count];
  NSMutableSet<NSString *> *seenRemotePaths = [NSMutableSet setWithCapacity:dylib_count];
  *outNetworkLoaderIdx = NSNotFound;

  for (uint32_t i = 0; i < dylib_count; i++) {
    TweakEntry *e = [TweakEntry new];
    e.index = i;

    // Remote path
    uint32_t name_len = 0;
    recv_exact(sock, &name_len, 4);
    char *name_buf = malloc(name_len + 1);
    recv_exact(sock, name_buf, name_len);
    name_buf[name_len] = '\0';
    e.remotePath = [NSString stringWithUTF8String:name_buf];
    free(name_buf);

    NSString *baseName = [e.remotePath.lastPathComponent stringByDeletingPathExtension];
    if ([baseName isEqualToString:@"NetworkLoader"])
      *outNetworkLoaderIdx = i;

    // Hash
    uint8_t hash_bytes[32];
    recv_exact(sock, hash_bytes, 32);
    e.sha256 = [NSData dataWithBytes:hash_bytes length:32];

    // Remote timestamp
    uint64_t remoteTs_net = 0;
    recv_exact(sock, &remoteTs_net, 8);
    e.remoteTs = (int64_t)OSSwapBigToHostInt64(remoteTs_net);

    e.position = -1;
    e.oldLocalName = @"";
    e.needsDownload = NO;

    if ([seenRemotePaths containsObject:e.remotePath]) {
      debug_print(@"WARNING: Duplicate remotePath in manifest: %@, index %u",
                  e.remotePath, i);
    } else {
      [seenRemotePaths addObject:e.remotePath];

      // Look up existing DB record to determine if download is needed
      sqlite3_stmt *st = NULL;
      sqlite3_prepare_v2(g_db,
          "SELECT position, unsignedHash, updateTime FROM tweaks WHERE remotePath=? LIMIT 1",
          -1, &st, NULL);
      sqlite3_bind_text(st, 1, e.remotePath.UTF8String, -1, SQLITE_TRANSIENT);

      if (sqlite3_step(st) == SQLITE_ROW) {
        e.position = sqlite3_column_int(st, 0);
        const void *hashBytes = sqlite3_column_blob(st, 1);
        int hashLen = sqlite3_column_bytes(st, 1);
        if (hashBytes && hashLen == 32) {
          NSData *oldHash = [NSData dataWithBytes:hashBytes length:hashLen];
          e.oldLocalName = derive_localName(e.remotePath, e.position, oldHash);
          if (![oldHash isEqualToData:e.sha256]) {
            debug_print(@"%@: hash changed", e.remotePath);
            e.needsDownload = YES;
          }
        }
        int64_t oldRemoteTs = sqlite3_column_int64(st, 2);
        if (oldRemoteTs != e.remoteTs) {
          debug_print(@"%@: remote timestamp changed (old: %lld, new: %lld)",
                      e.remotePath, oldRemoteTs, e.remoteTs);
          e.needsDownload = YES;
        }
      } else {
        debug_print(@"%@: new entry, no existing local name", e.remotePath);
        e.needsDownload = YES;
      }
      sqlite3_finalize(st);
    }

    e.localName = derive_localName(e.remotePath, e.position, e.sha256);
    if (e.needsDownload) {
      debug_print(@"%@: marked for download", e.remotePath);
      e.downloadPath = [downloadsDir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%u.dylib", i]];
    } else {
      debug_print(@"%@: up to date, no download needed", e.remotePath);
      e.downloadPath = [tweaksDir stringByAppendingPathComponent:e.localName];
    }
    debug_print(@"%@: local=%@, old=%@, position=%d, downloadPath=%@",
                e.remotePath, e.localName, e.oldLocalName, e.position, e.downloadPath);

    [entries addObject:e];
  }
  return entries;
}

// ── Phase 3: Send needed indices to server, receive files into staging dir ─
static BOOL requestAndReceiveFiles(int sock, NSArray<TweakEntry *> *entries) {
  NSMutableArray<TweakEntry *> *needed = [NSMutableArray array];
  for (TweakEntry *e in entries) {
    if (e.needsDownload)
      [needed addObject:e];
  }

  uint32_t needed_count = htonl((uint32_t)needed.count);
  send(sock, &needed_count, 4, 0);
  for (TweakEntry *e in needed) {
    uint32_t idx = htonl(e.index);
    send(sock, &idx, 4, 0);
  }
  debug_print(@"Requesting %lu/%lu files…", (unsigned long)needed.count,
              (unsigned long)entries.count);

  for (TweakEntry *e in needed) {
    uint32_t data_len = 0;
    recv_exact(sock, &data_len, 4);
    data_len = ntohl(data_len);
    debug_print(@"#%u: receiving %@ (%u bytes)…", e.index, e.remotePath, data_len);

    FILE *fp = fopen(e.downloadPath.UTF8String, "wb");
    if (!fp)
      return NO;
    if (!recv_to_file(sock, fp, data_len)) {
      debug_print(@"ERROR: Failed to receive %@", e.downloadPath);
      fclose(fp);
      return NO;
    }
    fclose(fp);
  }
  return YES;
}

// ── Phase 3.5: Copy NetworkLoader to LiveTweaks/ for next-boot pickup ─────
static void copyNetworkLoaderForNextBoot(NSUInteger networkLoaderIdx,
                                          NSArray<TweakEntry *> *entries,
                                          NSString *containerPath) {
  if (networkLoaderIdx == NSNotFound)
    return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *liveTweaks =
      [containerPath stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
  [fm createDirectoryAtPath:liveTweaks withIntermediateDirectories:YES
                 attributes:nil error:nil];
  NSString *dst = [liveTweaks stringByAppendingPathComponent:@"NetworkLoader.dylib"];
  [fm removeItemAtPath:dst error:nil];
  TweakEntry *e = entries[networkLoaderIdx];
  NSError *copyErr = nil;
  if (![fm copyItemAtPath:e.downloadPath toPath:dst error:&copyErr]) {
    debug_print(@"Failed to copy NetworkLoader to LiveTweaks: %@", copyErr);
  } else {
    debug_print(@"NetworkLoader ready in LiveTweaks.");
  }
}

// ── Phase 4: Update DB, delete old files, move staged files into tweaksDir ─
// Returns YES if NetworkLoader itself was updated (caller should hot-swap it).
static BOOL updateFilesAndDB(NSArray<TweakEntry *> *entries,
                              NSString *tweaksDir,
                              NSUInteger networkLoaderIdx) {
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL loaderChanged = NO;

  for (TweakEntry *e in entries) {
    if (!e.needsDownload)
      continue;
    if (e.index == networkLoaderIdx)
      loaderChanged = YES;

    debug_print(@"Updating: %@", e.downloadPath);

    if (e.oldLocalName.length > 0)
      unlink([tweaksDir stringByAppendingPathComponent:e.oldLocalName].UTF8String);

    int position = db_upsert(e.remotePath, e.sha256, e.remoteTs);
    e.position = position;

    NSString *finalName = derive_localName(e.remotePath, position, e.sha256);
    e.localName = finalName; // keep entry in sync with DB-assigned position
    NSString *finalPath = [tweaksDir stringByAppendingPathComponent:finalName];
    debug_print(@"Moving %@ to tweaks as %@…", e.downloadPath, finalName);
    NSError *moveErr = nil;
    if (![fm moveItemAtPath:e.downloadPath toPath:finalPath error:&moveErr]) {
      debug_print(@"Move to tweaks failed: %@", moveErr);
      continue;
    }
    e.downloadPath = finalPath;
  }
  return loaderChanged;
}

// ── Phase 5: dlopen all tweaks (except self) ──────────────────────────────
static void loadAllTweaks(NSArray<TweakEntry *> *entries, NSString *tweaksDir) {
  NSMutableSet<NSString *> *loadedNames = [NSMutableSet set];
  debug_print(@"Loading %lu tweaks…", (unsigned long)entries.count);

  for (TweakEntry *e in entries) {
    NSString *baseName = [e.remotePath.lastPathComponent stringByDeletingPathExtension];
    if ([baseName isEqualToString:@"NetworkLoader"])
      continue;
    if ([loadedNames containsObject:e.localName]) {
      debug_print(@"Already loaded %@, skipping dlopen", e.localName);
      continue;
    }
    NSString *fullPath = [tweaksDir stringByAppendingPathComponent:e.localName];
    [loadedNames addObject:e.localName];

    if ([baseName isEqualToString:@"Frida"]) {
      debug_print(@"Loading Frida from %@... %@:%@", fullPath, CONTROLLER_IP, @27042);
      // Frida Gadget needs a config file written before dlopen.
      // Use the controller as the portal (port 27042 = Frida default).
      loadFridaGadget(fullPath);
      debug_print(@"Frida loaded!");
      continue;
    }

    debug_print(@"Loading %s…", fullPath.UTF8String);
    void *h = dlopen(fullPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
      debug_print(@"[!] Failed to load %s: %s", fullPath.UTF8String, dlerror());
      exit(1);
    }
    debug_print(@"Loaded %s successfully.", fullPath.UTF8String);
  }
  debug_print(@"Finished loading");
}

// ── Phase 6: Monitor connection — abort when server disconnects/kills ──────
static void monitorConnection(int sock) {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    debug_print(@"Waiting for kill ping or connection loss…");
    char monitor[1];
    recv(sock, monitor, 1, 0);
    abort();
  });
}

// ── Entry point ───────────────────────────────────────────────────────────
void init() {
  int sock = connectToServer();
  if (sock < 0)
    exit(1);

  NSString *containerPath = getActualContainerPath();
  NSString *tweaksDir =
      [containerPath stringByAppendingPathComponent:@"Documents/NetworkTweaks"];
  NSString *downloadsDir = [tweaksDir stringByAppendingPathComponent:@".Downloads"];
  [[NSFileManager defaultManager] createDirectoryAtPath:downloadsDir
      withIntermediateDirectories:YES attributes:nil error:nil];
  db_open([tweaksDir stringByAppendingPathComponent:@"tweaks.db"]);

  NSUInteger networkLoaderIdx;
  NSArray<TweakEntry *> *entries =
      receiveManifest(sock, tweaksDir, downloadsDir, &networkLoaderIdx);

  if (!requestAndReceiveFiles(sock, entries))
    exit(1);

  NSMutableArray<NSString *> *receivedPaths = [NSMutableArray array];
  for (TweakEntry *e in entries) {
    if (e.needsDownload)
      [receivedPaths addObject:e.downloadPath];
  }
  if (!signReceivedTweaks(receivedPaths)) {
    debug_print(@"ERROR: Failed to sign received tweaks");
    exit(1);
  }

  copyNetworkLoaderForNextBoot(networkLoaderIdx, entries, containerPath);

  BOOL loaderChanged = updateFilesAndDB(entries, tweaksDir, networkLoaderIdx);
  [[NSFileManager defaultManager] removeItemAtPath:downloadsDir error:nil];

  if (networkLoaderIdx != NSNotFound && loaderChanged) {
    debug_print(@"NetworkLoader was updated, switching to new version…");
    dlopen(entries[networkLoaderIdx].downloadPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    return;
  }

  loadAllTweaks(entries, tweaksDir);
  monitorConnection(sock);
}
