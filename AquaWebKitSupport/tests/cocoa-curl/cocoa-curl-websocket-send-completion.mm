// A page WebSocket's send completes once curl has taken the frame's last byte, which is when WebKit takes it out of
// bufferedAmount: with a reader taking 2 MB/s the amount falls at the reader's pace, and with a reader that takes
// nothing it stays at what the socket could not hold.
// Expects cocoa-curl-websocket-send-completion-server.py on 18992.
#import <WebKit/WKWebView.h>
#import "cocoa-curl-websocket-page.h"

static NSString *const origin = @"http://127.0.0.1:18992/";

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WebSocketPageDelegate *delegate = [WebSocketPageDelegate new];
        WKWebView *view = makeWebSocketView(delegate);

        // 32 messages of 128 KB, 4 MB in all: about two seconds of the reader.
        NSString *slow = runWebSocketPage(view, origin, @
            "const chunk = new Uint8Array(128 * 1024);\n"
            "const total = 32 * chunk.length;\n"
            "let atOneSecond = -1, drainedAfter = -1, start = 0;\n"
            "await socketEvents('ws://127.0.0.1:18992/slow-sink', { timeout: 20000, onOpen: socket => {\n"
            "    for (let i = 0; i < 32; ++i) socket.send(chunk);\n"
            "    start = performance.now();\n"
            "    setTimeout(() => { atOneSecond = socket.bufferedAmount; }, 1000);\n"
            "    const poll = setInterval(() => { if (!socket.bufferedAmount) { clearInterval(poll); drainedAfter = performance.now() - start; socket.close(); } }, 50);\n"
            "} });\n"
            "return { total, atOneSecond, drainedAfter: Math.round(drainedAfter) };", 40);
        NSDictionary *slowResult = [NSJSONSerialization JSONObjectWithData:[slow dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        long total = [slowResult[@"total"] longValue], atOneSecond = [slowResult[@"atOneSecond"] longValue], drained = [slowResult[@"drainedAfter"] longValue];
        expectTrue("slow reader: after 1 s some of the messages have completed and some have not", atOneSecond > 0 && atOneSecond < total, slow);
        expectTrue("slow reader: the rest complete at the reader's pace", drained > 1200 && drained < 10000, slow);

        NSString *stalled = runWebSocketPage(view, origin, @
            "const chunk = new Uint8Array(128 * 1024);\n"
            "let early = -1, late = -1;\n"
            "await socketEvents('ws://127.0.0.1:18992/stall', { timeout: 5000, settle: 3000, onOpen: socket => {\n"
            "    for (let i = 0; i < 32; ++i) socket.send(chunk);\n"
            "    setTimeout(() => { early = socket.bufferedAmount; }, 1000);\n"
            "    setTimeout(() => { late = socket.bufferedAmount; }, 2500);\n"
            "} });\n"
            "return { total: 32 * chunk.length, early, late };", 20);
        NSDictionary *stalledResult = [NSJSONSerialization JSONObjectWithData:[stalled dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        long stalledTotal = [stalledResult[@"total"] longValue], early = [stalledResult[@"early"] longValue], late = [stalledResult[@"late"] longValue];
        expectTrue("stalled reader: what the socket could not take stays unsent", early > stalledTotal / 2 && late == early, stalled);

        printf("WebSocket send completion: FAILED=%u\n", webSocketFailures);
        return webSocketFailures ? 1 : 0;
    }
}
