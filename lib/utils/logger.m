#ifndef APP_DYLIB_PATCHES_UTILS_LOGGER_HPP
#define APP_DYLIB_PATCHES_UTILS_LOGGER_HPP

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <os/log.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

// ── C struct-based logger ──

typedef struct NetworkLogger {
  char name[64];
  int sock;
  struct sockaddr_in addr;
  dispatch_queue_t send_queue;
} NetworkLogger;

// ── Functions (static inline, header-only) ──

static inline void network_logger_init(NetworkLogger *l, const char *name,
                                       const char *ip, uint16_t port) {
  memset(l, 0, sizeof(*l));
  strlcpy(l->name, name, sizeof(l->name));

  l->sock = socket(AF_INET, SOCK_DGRAM, 0);
  l->addr.sin_family = AF_INET;
  l->addr.sin_port = htons(port);
  inet_pton(AF_INET, ip, &l->addr.sin_addr);

  l->send_queue =
      dispatch_queue_create("com.networklogger.send", DISPATCH_QUEUE_SERIAL);
  NSLog(@"[%s] Initialized (-> %s:%u)", l->name, ip, port);
}

static inline void network_logger_print(NetworkLogger *l, NSString *message) {
  NSData *data = [[NSString stringWithFormat:@"[%s] %@\n", l->name, message]
      dataUsingEncoding:NSUTF8StringEncoding];
  // Local log
  NSLog(@"[NSLog] [%s] %@", l->name, message);
  os_log(OS_LOG_DEFAULT, "%@", message);

  // UDP send (async)
  int fd = l->sock;
  struct sockaddr_in dst = l->addr;

  dispatch_async(l->send_queue, ^{
    sendto(fd, data.bytes, data.length, 0, (struct sockaddr *)&dst,
           sizeof(dst));
  });
}

static inline void network_logger_destroy(NetworkLogger *l) {
  if (l->sock >= 0) {
    close(l->sock);
    l->sock = -1;
  }
  if (l->send_queue) {
    dispatch_release(l->send_queue);
    l->send_queue = NULL;
  }
}

// ── Convenience macros ──

static NetworkLogger logger; // Global instance

// Declare + initialise a NetworkLogger on the stack (or as a static/global).
//   INIT_LOGGER(logger, "MyTweak", "192.168.1.50", 11909);
#define INIT_LOGGER(name)                                                      \
  network_logger_init(&logger, name, "192.168.1.23", 8889);

// printf-style logging through a NetworkLogger.
//   debug_log(&logger, @"count = %d", n);
#define debug_print(fmt, ...)                                                  \
  do {                                                                         \
    network_logger_print(&logger,                                              \
                         [NSString stringWithFormat:(fmt), ##__VA_ARGS__]);    \
  } while (0);

#endif
