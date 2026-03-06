#ifndef APP_DYLIB_PATCHES_LOGGER_H
#define APP_DYLIB_PATCHES_LOGGER_H

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <os/log.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "lc_utils.h"

typedef struct NetworkLogger {
  char name[64];
  int sock;
  struct sockaddr_in addr;
  dispatch_queue_t send_queue;
} NetworkLogger;

static NetworkLogger logger; // Global instance

static inline void network_logger_init(NetworkLogger *l, const char *name,
                                       uint16_t port) {
  os_log(OS_LOG_DEFAULT, "Initializing NetworkLogger: %{public}s", name);
  memset(l->name, 0, sizeof(l->name));
  l->sock = 0;
  memset(&l->addr, 0, sizeof(l->addr));
  l->send_queue = NULL;
  strlcpy(l->name, name, sizeof(l->name));
  NSString* controllerIP = getControllerIP();
  if (controllerIP != nil) {
    l->sock = socket(AF_INET, SOCK_DGRAM, 0);
    l->addr.sin_family = AF_INET;
    l->addr.sin_port = htons(port);
    inet_pton(AF_INET, controllerIP.UTF8String, &l->addr.sin_addr);
    l->send_queue = dispatch_queue_create("com.networklogger.send", DISPATCH_QUEUE_SERIAL);
  }
}

static NSString *logFormat = @"[%s] %@";

static inline NSString* network_logger_print(NetworkLogger *l, NSString *message) {
  NSString *dataString = [NSString stringWithFormat:logFormat, l->name, message];
  os_log(OS_LOG_DEFAULT, "%s", dataString.UTF8String);
  if ((CONTROLLER_IP != nil) && (l->sock != 0)) {
    dispatch_async(l->send_queue, ^{
      NSData *data = [[dataString stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
      sendto(l->sock, data.bytes, data.length, 0, (struct sockaddr *)&(l->addr), sizeof(l->addr));
    });
  }
  return dataString;
}

static inline void network_logger_destroy(NetworkLogger *l) {
  if (l->sock >= 0) {
    close(l->sock);
    l->sock = -1;
  }
  if (l->send_queue) {
    #if !__has_feature(objc_arc)
    dispatch_release(l->send_queue);
    #endif
    l->send_queue = NULL;
  }
}

#define debug_print(fmt, ...) do {                                                      \
    network_logger_print(&logger, [NSString stringWithFormat:(fmt), ##__VA_ARGS__]);    \
  } while (0);

#define INIT_LOGGER(name)                                                      \
  do {                                                                         \
    network_logger_init(&logger, name, 8889);                                  \
    debug_print(@"Logger initialized");                                        \
  } while (0);

#endif
