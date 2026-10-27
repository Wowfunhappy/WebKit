// HTTP authentication of a page WebSocket's handshake, against cocoa-curl-websocket-auth-server.py on 18986, run by
// cocoa-curl-websocket-kerberos.py, which owns the Kerberos realm the Negotiate cases use.
//
// With no argument: NTLM with the navigation delegate's credential opens after one challenge, and a credential the
// server refuses is put to the delegate again with a failure count of one. A 401 offering several schemes puts them to
// the delegate strongest first with 10.9 NSURLSession's realms, and rejecting a protection space moves on to the next.
// With "ticket", "password" or "cancel": Negotiate with the user's Kerberos ticket (default handling), with the
// principal's password, and cancelled; the principal is $WEBSOCKET_KERBEROS_PRINCIPAL.
#import <WebKit/WKWebView.h>
#import "cocoa-curl-websocket-page.h"

struct Seen {
    unsigned challenges { 0 };
    NSInteger lastFailureCount { 0 };
    NSString *method { nil };
    // Retained: this program is built without ARC, and the page runs the run loop between challenges.
    NSMutableArray<NSString *> *presented { [[NSMutableArray alloc] init] };
};

// |answer| decides each challenge from the challenge and the number of challenges before it.
static NSString *run(WKWebView *view, WebSocketPageDelegate *delegate, NSString *path, Seen& seen,
    void (^answer)(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer, unsigned))
{
    seen = { };
    Seen* record = &seen;
    delegate.challengeHandler = ^(NSURLAuthenticationChallenge *challenge, WebSocketChallengeAnswer completion) {
        unsigned before = record->challenges++;
        record->lastFailureCount = challenge.previousFailureCount;
        record->method = [challenge.protectionSpace.authenticationMethod copy];
        [record->presented addObject:[NSString stringWithFormat:@"%@@%@", [record->method stringByReplacingOccurrencesOfString:@"NSURLAuthenticationMethod" withString:@""], challenge.protectionSpace.realm]];
        answer(challenge, completion, before);
    };
    NSString *script = [NSString stringWithFormat:@"return (await socketEvents('ws://127.0.0.1:18986%@', { settle: 500, timeout: 15000 })).events.join(',');", path];
    return [runWebSocketPage(view, @"http://127.0.0.1:18986/", script) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

static void report(const char *what, bool passed, NSString *events, const Seen& seen)
{
    printf("%s: events=[%s] challenges=%u lastFailureCount=%ld method=%s presented=[%s] %s\n", what, events.UTF8String ?: "(no result)", seen.challenges,
        (long)seen.lastFailureCount, seen.method.UTF8String ?: "-", [seen.presented componentsJoinedByString:@","].UTF8String, passed ? "PASS" : "FAIL");
    webSocketFailures += !passed;
}

static NSURLCredential *credential(NSString *user, NSString *password)
{
    return [NSURLCredential credentialWithUser:user password:password persistence:NSURLCredentialPersistenceNone];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WebSocketPageDelegate *delegate = [WebSocketPageDelegate new];
        WKWebView *view = makeWebSocketView(delegate);
        NSString *opened = @"open,message:hello";
        NSString *failed = @"error,close:1006";
        Seen seen;

        if (argc == 2) {
            NSString *mode = [NSString stringWithUTF8String:argv[1]];
            NSString *principal = [NSProcessInfo processInfo].environment[@"WEBSOCKET_KERBEROS_PRINCIPAL"];
            if (!principal.length || !([mode isEqualToString:@"ticket"] || [mode isEqualToString:@"password"] || [mode isEqualToString:@"cancel"]))
                return 2;
            NSString *events = run(view, delegate, @"/negotiate", seen, ^(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer completion, unsigned before) {
                if (before || [mode isEqualToString:@"cancel"])
                    completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                else if ([mode isEqualToString:@"ticket"])
                    completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
                else
                    completion(NSURLSessionAuthChallengeUseCredential, credential(principal, @"correct-password"));
            });
            bool passed = seen.challenges == 1 && [seen.method isEqualToString:NSURLAuthenticationMethodNegotiate]
                && [events isEqualToString:[mode isEqualToString:@"cancel"] ? failed : opened];
            report([[@"Negotiate " stringByAppendingString:mode] UTF8String], passed, events, seen);
            return !passed;
        }

        NSString *events = run(view, delegate, @"/socket", seen, ^(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer completion, unsigned before) {
            if (before)
                completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            else
                completion(NSURLSessionAuthChallengeUseCredential, credential(@"CURL\\curl-test", @"correct-password"));
        });
        report("NTLM correct credential: opens after one challenge", [events isEqualToString:opened] && seen.challenges == 1 && [seen.method isEqualToString:NSURLAuthenticationMethodNTLM], events, seen);

        events = run(view, delegate, @"/socket", seen, ^(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer completion, unsigned before) {
            if (before)
                completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            else
                completion(NSURLSessionAuthChallengeUseCredential, credential(@"CURL\\curl-test", @"wrong-password"));
        });
        report("NTLM refused credential: asked again with one failure, then cancelled", [events isEqualToString:failed] && seen.challenges == 2 && seen.lastFailureCount == 1, events, seen);

        // 10.9 NSURLSession's order and realms for these offers, measured against the same responses over http.
        events = run(view, delegate, @"/multi", seen, ^(NSURLAuthenticationChallenge *, WebSocketChallengeAnswer completion, unsigned) {
            completion(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        });
        report("four schemes, each rejected: strongest first, then the handshake fails", [events isEqualToString:failed]
            && [[seen.presented componentsJoinedByString:@","] isEqualToString:@"Negotiate@127.0.0.1,NTLM@127.0.0.1,HTTPDigest@127.0.0.1,Default@127.0.0.1"], events, seen);

        events = run(view, delegate, @"/basic-digest", seen, ^(NSURLAuthenticationChallenge *challenge, WebSocketChallengeAnswer completion, unsigned) {
            if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic] && !challenge.previousFailureCount)
                completion(NSURLSessionAuthChallengeUseCredential, credential(@"u", @"p"));
            else
                completion(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        });
        report("one field, Digest rejected, Basic answered: opens", [events isEqualToString:opened]
            && [[seen.presented componentsJoinedByString:@","] isEqualToString:@"HTTPDigest@dr,Default@dr"], events, seen);

        printf("WebSocket authentication: FAILED=%u\n", webSocketFailures);
        return webSocketFailures ? 1 : 0;
    }
}
