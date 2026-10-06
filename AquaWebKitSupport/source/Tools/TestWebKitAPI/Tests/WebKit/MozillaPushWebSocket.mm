#import "config.h"

#import "Helpers/Test.h"
#import "MozillaPushWebSocket.h"
#import <wtf/RetainPtr.h>

#if USE(MOZILLA_PUSH_SERVICE)

@interface MozillaPushWebSocket (Testing)
- (BOOL)tryCompleteHandshake;
- (void)parseFrames;
@end

@interface TestPushWebSocketDelegate : NSObject <MozillaPushWebSocketDelegate>
@property (nonatomic) BOOL opened;
@property (nonatomic, retain) NSError *error;
@property (nonatomic, retain) NSMutableArray<NSString *> *messages;
@end

@implementation TestPushWebSocketDelegate

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    self.messages = [NSMutableArray array];
    return self;
}

- (void)webSocketDidOpen:(MozillaPushWebSocket *)webSocket
{
    self.opened = YES;
}

- (void)webSocket:(MozillaPushWebSocket *)webSocket didReceiveMessage:(NSString *)message
{
    [self.messages addObject:message];
}

- (void)webSocket:(MozillaPushWebSocket *)webSocket didCloseWithError:(NSError *)error
{
    self.error = error;
}

- (void)webSocketDidReceiveControlFrame:(MozillaPushWebSocket *)webSocket
{
}

@end

static RetainPtr<MozillaPushWebSocket> makeWebSocket(TestPushWebSocketDelegate *delegate)
{
    auto socket = adoptNS([[MozillaPushWebSocket alloc] initWithHost:@"example.invalid" port:443 path:@"/push" useTLS:YES delegate:delegate]);
    [socket setValue:@"expected-accept" forKey:@"expectedAcceptKey"];
    return socket;
}

static void appendWebSocketInput(MozillaPushWebSocket *socket, NSData *data)
{
    NSMutableData *readBuffer = [socket valueForKey:@"readBuffer"];
    [readBuffer appendData:data];
}

static NSData *validUpgradeResponse()
{
    NSString *response = @"HTTP/1.1 101 Switching Protocols\r\n"
        "Sec-WebSocket-Accept: expected-accept\r\n"
        "Upgrade: websocket\r\n"
        "Connection: keep-alive, Upgrade\r\n\r\n";
    return [response dataUsingEncoding:NSUTF8StringEncoding];
}

namespace TestWebKitAPI {

TEST(MozillaPushWebSocket, AcceptsValidUpgradeAndTextFrame)
{
    auto delegate = adoptNS([[TestPushWebSocketDelegate alloc] init]);
    auto socket = makeWebSocket(delegate.get());
    appendWebSocketInput(socket.get(), validUpgradeResponse());

    ASSERT_TRUE([socket tryCompleteHandshake]);
    EXPECT_TRUE(delegate.get().opened);
    EXPECT_NULL(delegate.get().error);

    const uint8_t textFrame[] = { 0x81, 0x02, 'o', 'k' };
    appendWebSocketInput(socket.get(), [NSData dataWithBytes:textFrame length:sizeof(textFrame)]);
    [socket parseFrames];

    ASSERT_EQ(delegate.get().messages.count, 1u);
    EXPECT_TRUE([delegate.get().messages[0] isEqualToString:@"ok"]);
}

TEST(MozillaPushWebSocket, RejectsUpgradeWithoutUpgradeHeader)
{
    auto delegate = adoptNS([[TestPushWebSocketDelegate alloc] init]);
    auto socket = makeWebSocket(delegate.get());
    NSString *response = @"HTTP/1.1 101 Switching Protocols\r\n"
        "Sec-WebSocket-Accept: expected-accept\r\n"
        "Connection: Upgrade\r\n\r\n";
    appendWebSocketInput(socket.get(), [response dataUsingEncoding:NSUTF8StringEncoding]);

    EXPECT_FALSE([socket tryCompleteHandshake]);
    ASSERT_NOT_NULL(delegate.get().error);
    EXPECT_TRUE([delegate.get().error.localizedDescription containsString:@"Upgrade header"]);
}

TEST(MozillaPushWebSocket, RejectsMaskedServerFrame)
{
    auto delegate = adoptNS([[TestPushWebSocketDelegate alloc] init]);
    auto socket = makeWebSocket(delegate.get());
    appendWebSocketInput(socket.get(), validUpgradeResponse());
    ASSERT_TRUE([socket tryCompleteHandshake]);

    const uint8_t maskedFrame[] = { 0x81, 0x80 };
    appendWebSocketInput(socket.get(), [NSData dataWithBytes:maskedFrame length:sizeof(maskedFrame)]);
    [socket parseFrames];

    ASSERT_NOT_NULL(delegate.get().error);
    EXPECT_TRUE([delegate.get().error.localizedDescription containsString:@"masked"]);
}

} // namespace TestWebKitAPI

#endif // USE(MOZILLA_PUSH_SERVICE)
