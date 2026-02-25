#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <sys/stat.h>

#define CONCAT_MACRO(A, B) A##B

#define SEND_DEBUG(sock, fmt, ...) do { \
    char msg[512]; \
    snprintf(msg, sizeof(msg), fmt "\n", ##__VA_ARGS__); \
    if (sock >= 0) send(sock, msg, strlen(msg), 0); \
} while (0);

#define die_now() do { \
    SEND_DEBUG(sock, "DYING!"); \
    if (sock >= 0) close(sock); \
    exit(1); \
} while (0);

__attribute__((constructor))
static void init() {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;

    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(8887);
    server_addr.sin_addr.s_addr = inet_addr("192.168.1.23");

    // Connect to the Mac bridge
    if (connect(sock, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        NSLog(@"[DylibLoader] Could not connect to bridge.");
        close(sock);
        sock = -1;
        die_now();
    }

    SEND_DEBUG(sock, "[DylibLoader] Connected. Preparing sandbox path...");

    // Get the absolute path to the sandbox Documents folder
    // NSHomeDirectory() is usually more stable than NSDocumentDirectory in LiveContainer
    NSString *homeDir = NSHomeDirectory();
    SEND_DEBUG(sock, "Home: %s", [homeDir UTF8String]);
    NSString *home = @"/private/var/mobile/Containers/Data/Application/EF9EB8C3-C3CA-4E39-92A6-A005FD1292EB/"; //NSHomeDirectory();
    NSString *tempPath = [home stringByAppendingPathComponent:@"Documents/Tweaks/inbox.dylib"];
    const char *path = [tempPath UTF8String];

    // Clean start
    unlink(path);

    FILE *fp = fopen(path, "wb");
    if (!fp) {
        SEND_DEBUG(sock, "[DylibLoader] ERROR: Cannot open %s for writing. Check permissions.", path);
        die_now();
    }

    SEND_DEBUG(sock, "[DylibLoader] Receiving binary data...");
    char buffer[8192];
    ssize_t bytes_received;
    size_t total_received = 0;

    while ((bytes_received = recv(sock, buffer, sizeof(buffer), 0)) > 0) {
        fwrite(buffer, 1, bytes_received, fp);
        total_received += bytes_received;
    }
    
    fclose(fp);

    if (total_received == 0) {
        SEND_DEBUG(sock, "[DylibLoader] ERROR: Received 0 bytes.");
        die_now();
    }

    // Ensure the kernel can execute the file
    //chmod(path, 0755);

    // Final attempt to load
    SEND_DEBUG(sock, "[DylibLoader] Attempting dlopen on: %s", path);
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    
    if (!handle) {
        const char *err = dlerror();
        SEND_DEBUG(sock, "[DylibLoader] CRITICAL FAILURE: %s", err ?: "Unknown dlopen error");
        
        // Shut down the connection and kill the app to prevent un-spoofed mic usage
        close(sock);
        NSLog(@"[DylibLoader] dlopen failed. Terminating process.");
        exit(1); 
    }

    SEND_DEBUG(sock, "[DylibLoader] SUCCESS: %zu bytes loaded. Spoof active.", total_received);
    close(sock);
}
