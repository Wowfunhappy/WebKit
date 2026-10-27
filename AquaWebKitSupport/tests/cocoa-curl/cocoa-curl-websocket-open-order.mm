// The order in which a page WebSocket reports what one read of the connection carried: a handshake followed by the
// connection's end opens, then closes abnormally; a frame or a Close that came with the handshake is delivered after
// the open; the peer's echo of the client's Close carries the code. No byte of a message reaches the server before its
// 101. A session whose proxy configuration (connectionProxyDictionary) names a PAC file reaches the host through the
// proxy that file returns, or through the next one it names when the first cannot be reached, and closing the socket
// ends a wait on a PAC file that never arrives.
// Expects cocoa-curl-websocket-open-order-server.py on 18994 and cocoa-curl-websocket-send-completion-server.py on
// 18992; the argument is the open-order fixture's log, which records the requests a proxy received.
#import <WebKit/WKWebView.h>
#import "cocoa-curl-websocket-page.h"

static NSString *const origin = @"http://127.0.0.1:18994/";

static NSString *eventsOf(WKWebView *view, NSString *path, NSString *options = @"{ settle: 500 }")
{
    NSString *script = [NSString stringWithFormat:@"return (await socketEvents('ws://127.0.0.1:18994%@', %@)).events.join(',');", path, options];
    return [runWebSocketPage(view, origin, script) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WebSocketPageDelegate *delegate = [WebSocketPageDelegate new];
        WKWebView *view = makeWebSocketView(delegate);

        expectResult("handshake then close in the same read: open, then abnormal close", eventsOf(view, @"/abort"), @"open,close:1006");
        expectResult("handshake and a frame in one read, connection up: open, then the message", eventsOf(view, @"/frame", @"{ settle: 1000 }"), @"open,message:hello");
        expectResult("handshake, close in a later read: open, then abnormal close", eventsOf(view, @"/late-close", @"{ settle: 1500 }"), @"open,close:1006");
        expectResult("handshake, a frame and the end in one read: open, the message, then abnormal close", eventsOf(view, @"/frame-eof"), @"open,message:hello,close:1006");
        expectResult("handshake, Close(1000) and the end in one read: open, then close 1000", eventsOf(view, @"/close-1000"), @"open,close:1000");
        expectResult("peer drops TCP after the client Close: close 1006", eventsOf(view, @"/drop-client-close", @"{ onOpen: socket => socket.close(4001) }"), @"open,close:1006");
        expectResult("peer echoes the client Close: the received code wins", eventsOf(view, @"/echo-client-close", @"{ onOpen: socket => socket.close(4001) }"), @"open,close:4001");

        NSString *lateOpen = runWebSocketPage(view, @"http://127.0.0.1:18992/",
            @"return (await socketEvents('ws://127.0.0.1:18992/late-open', { onOpen: socket => socket.send('sent at open'), onMessage: socket => socket.close() })).events[1];");
        expectResult("a message sent at open reaches the server only after its 101", lateOpen, @"\"message:early 0\"");

        WKWebView *pacView = makeWebSocketView(delegate, @{ @"ProxyAutoConfigEnable": @1, @"ProxyAutoConfigURLString": @"http://127.0.0.1:18994/proxy.pac" });
        NSString *proxied = [runWebSocketPage(pacView, origin, @"return (await socketEvents('ws://proxied.invalid/frame', { settle: 500 })).events.join(',');")
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        expectResult("session PAC file routes the host through an HTTP proxy", proxied, @"open,message:hello");
        if (argc > 1) {
            NSString *log = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
            expectTrue("the proxy received the handshake in absolute form", [log rangeOfString:@"proxied request /frame"].location != NSNotFound, nil);
        }

        WKWebView *failoverView = makeWebSocketView(delegate, @{ @"ProxyAutoConfigEnable": @1, @"ProxyAutoConfigURLString": @"http://127.0.0.1:18994/failover.pac" });
        NSString *failedOver = [runWebSocketPage(failoverView, origin, @"return (await socketEvents('ws://failover.invalid/frame', { settle: 500 })).events.join(',');")
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        expectResult("session PAC file whose first proxy is down: the next one carries the handshake", failedOver, @"open,message:hello");

        WKWebView *stalledView = makeWebSocketView(delegate, @{ @"ProxyAutoConfigEnable": @1, @"ProxyAutoConfigURLString": @"http://127.0.0.1:18994/stalled.pac" });
        NSDate *start = [NSDate date];
        NSString *stalled = [runWebSocketPage(stalledView, origin, @"return (await socketEvents('ws://127.0.0.1:18994/frame', { timeout: 5000, onCreate: socket => setTimeout(() => socket.close(), 500) })).events.join(',');")
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        NSTimeInterval elapsed = -start.timeIntervalSinceNow;
        expectResult("PAC file never arrives: closing the socket ends the wait", stalled, @"error,close:1006");
        expectTrue("the closed socket reports at once", elapsed < 3, [NSString stringWithFormat:@"%.1f s", elapsed]);

        printf("WebSocket open order: FAILED=%u\n", webSocketFailures);
        return webSocketFailures ? 1 : 0;
    }
}
