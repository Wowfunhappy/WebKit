/*
 * A WebSocket task's server certificate goes to the session delegate on this port
 * (MavericksSupport/polyfill/polyfills/webkit/websocket.mm), because 10.9's CFStream does the TLS
 * handshake itself and would otherwise decide for itself and never ask. The stream's own chain
 * validation is off, so what stands in its place has to hold the whole connection, not just the bytes
 * this side writes -- these two tests are the A/B for that.
 */

#import "config.h"

#import "HTTPServer.h"
#import "PlatformUtilities.h"
#import "TestNavigationDelegate.h"
#import "TestUIDelegate.h"
#import "TestWKWebView.h"
#import <WebKit/WKHTTPCookieStore.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/MakeString.h>

namespace TestWebKitAPI {

static RetainPtr<NSArray<NSHTTPCookie *>> allCookies(WKHTTPCookieStore *store)
{
    __block RetainPtr<NSArray<NSHTTPCookie *>> result;
    __block bool done = false;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        result = cookies;
        done = true;
    }];
    Util::run(&done);
    return result;
}

static void removeAllCookies(WKHTTPCookieStore *store)
{
    auto cookies = allCookies(store);
    for (NSHTTPCookie *cookie in cookies.get()) {
        __block bool done = false;
        [store deleteCookie:cookie completionHandler:^{ done = true; }];
        Util::run(&done);
    }
}

// PerformDefaultHandling hands the decision back to the evaluation this port does in place of the chain
// check CFStream would have done -- the same verdict a task falls back to when nothing implements
// URLSession:task:didReceiveChallenge:completionHandler: or the challenge cannot be built. A
// self-signed certificate must lose there too.
enum class TrustAnswer : uint8_t { Reject, Accept, DefaultHandling };

// A wss server whose certificate the delegate is asked about, answering the handshake as soon as the
// TLS session is up rather than waiting for the client's request: its Set-Cookie is sitting in the
// stream while the certificate is still with the delegate. The cookie is the observable — it says
// whether the connection was used before it was answered for.
static bool webSocketHandshakeCookieIsStored(TrustAnswer answer)
{
    HTTPServer webSocketServer(HTTPServer::UseCoroutines::Yes, [] (Connection connection) -> ConnectionTask {
        co_await connection.awaitableSend(
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: 0000000000000000000000000000=\r\n"
            "Set-Cookie: WebSocketServerTrust=1\r\n"
            "\r\n"_s);
    }, HTTPServer::Protocol::Https);

    HTTPServer pageServer({ { "/"_s, HTTPResponse(makeString(
        "<script>"
        "let ws = new WebSocket('wss://127.0.0.1:"_s, webSocketServer.port(), "/websocket');"
        "ws.onopen = () => alert('open');"
        "ws.onerror = () => alert('error');"
        "</script>"_s)) } });

    auto webView = adoptNS([TestWKWebView new]);
    WKHTTPCookieStore *cookieStore = [[webView configuration].websiteDataStore httpCookieStore];
    removeAllCookies(cookieStore);

    auto navigationDelegate = adoptNS([TestNavigationDelegate new]);
    navigationDelegate.get().didReceiveAuthenticationChallenge = ^(WKWebView *, NSURLAuthenticationChallenge *challenge, void (^completionHandler)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
        switch (answer) {
        case TrustAnswer::Accept:
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
            break;
        case TrustAnswer::DefaultHandling:
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            break;
        case TrustAnswer::Reject:
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            break;
        }
    };
    auto uiDelegate = adoptNS([TestUIDelegate new]);
    [webView setNavigationDelegate:navigationDelegate.get()];
    [webView setUIDelegate:uiDelegate.get()];
    [webView loadRequest:pageServer.request()];

    // The accept key above is not the one the client computed, so the handshake fails either way; what
    // differs is whether the response was read at all.
    EXPECT_WK_STREQ("error", [uiDelegate waitForAlert]);

    auto cookies = allCookies(cookieStore);
    for (NSHTTPCookie *cookie in cookies.get()) {
        if ([cookie.name isEqualToString:@"WebSocketServerTrust"])
            return true;
    }
    return false;
}

TEST(WebSocket, ServerTrustRejectedHandshakeSetsNoCookie)
{
    EXPECT_FALSE(webSocketHandshakeCookieIsStored(TrustAnswer::Reject));
}

TEST(WebSocket, ServerTrustAcceptedHandshakeSetsCookie)
{
    EXPECT_TRUE(webSocketHandshakeCookieIsStored(TrustAnswer::Accept));
}

TEST(WebSocket, ServerTrustDefaultHandlingSetsNoCookie)
{
    EXPECT_FALSE(webSocketHandshakeCookieIsStored(TrustAnswer::DefaultHandling));
}

} // namespace TestWebKitAPI
