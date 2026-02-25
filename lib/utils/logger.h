#ifndef APP_DYLIB_PATCHES_UTILS_LOGGER_H
#define APP_DYLIB_PATCHES_UTILS_LOGGER_H

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface BaseLogger : NSObject
@property(nonatomic, strong) NSString *name;
- (instancetype)initWithName:(NSString *)name;
- (void)print:(NSString *)message;
@end

@interface NetworkLogger : BaseLogger
@property(nonatomic, assign) int sock;
@property(nonatomic, assign) struct sockaddr_in addr;
@property(nonatomic, strong) dispatch_queue_t sendQueue;
- (instancetype)initWithName:(NSString *)name address:(NSString *)address port:(uint16_t)port;
- (void)print:(NSString *)message;
@end

#endif
