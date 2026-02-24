#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <os/log.h>

#define debug_print(fmt, ...) \
do { \
    NSString *formatted = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    os_log(OS_LOG_DEFAULT, "%{public}@", formatted); \
} while(0)



// Use BOOL for return type and correctly handle file writing
BOOL recv_to_file(int sock, FILE* fp, size_t total_len) {
    char buffer[8192];
    size_t received_so_far = 0;

    while (received_so_far < total_len) {
        // Calculate how much we still need, but don't exceed our 8KB buffer
        size_t to_read = total_len - received_so_far;
        if (to_read > sizeof(buffer)) to_read = sizeof(buffer);

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

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) exit(1);

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

    NSString *basePath = [@"/private/var/mobile/Containers/Data/Application/EF9EB8C3-C3CA-4E39-92A6-A005FD1292EB/" stringByAppendingPathComponent:@"Documents/Tweaks/LiveTweaks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:basePath withIntermediateDirectories:YES attributes:nil error:nil];
    void** objs = malloc(sizeof(void*)*dylib_count);

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
        
        uint32_t total_read = 0;
        NSString *fileName = [NSString stringWithUTF8String:name_buf];
        NSString *fullPath = [basePath stringByAppendingPathComponent:fileName];
        const char *path = [fullPath UTF8String];
        debug_print(@"[DylibLoader] #%d needs to recv %d into %s", i, data_len, path);
    
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

        // dlopen on Main Thread
        void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            debug_print(@"[!] Failed to load %s: %s", name_buf, dlerror());
            exit(1);
        }
        objs[i] = h;

        free(name_buf);
    }
    debug_print(@"[DylibLoader] Finished loading");
/*    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    debug_print(@"[DylibLoader] Finished loading - now im gonna wait");
        char monitor[1];
        while (recv(sock, monitor, 1, 0) > 0) { }    
        debug_print(@"[*] Connection lost. Killing app.");
        exit(0); 
    });*/
}

__attribute__((constructor))
static void init() {
    start_bridge_listener();
}
