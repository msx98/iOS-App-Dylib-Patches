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

@implementation BaseLogger
- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _name = name;
    }
    [self print:@"Initialized"];
    return self;
}
- (void)print:(NSString *)message {
    NSLog(@"[%@] %@", self.name, message);
}
@end

@implementation NetworkLogger
- (instancetype)initWithName:(NSString *)name address:(NSString *)address port:(uint16_t)port {
    self = [super initWithName:name];
    if (self) {
        _sock = socket(AF_INET, SOCK_DGRAM, 0);
        memset(&_addr, 0, sizeof(_addr));
        _addr.sin_family = AF_INET;
        _addr.sin_port = htons(port);
        inet_pton(AF_INET, [address UTF8String], &_addr.sin_addr);
        _sendQueue = dispatch_queue_create("com.networklogger.send", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)print:(NSString *)message {
    [super print:message];
    int fd = self.sock;
    struct sockaddr_in dest = self.addr;
    NSData *data = [[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(self.sendQueue, ^{
        sendto(fd, data.bytes, data.length, 0,
               (struct sockaddr *)&dest, sizeof(dest));
    });
}
- (void)dealloc {
    if (_sock >= 0) {
        close(_sock);
    }
    [super dealloc];
}
@end
