// A page WebSocket's server certificate and client certificate, answered as a load's are. A chain the platform
// trusts opens with no challenge. An untrusted chain is put to the navigation delegate once, on the main thread, and
// opens only when the delegate answers UseCredential; default handling, rejecting the protection space and cancelling
// all fail it. A server that asks for a client certificate gets the identity the delegate supplies, after the
// server-trust challenge, over TLS 1.2 and TLS 1.3; without one it refuses the connection.
// Expects run.sh's fixtures: the root-signed server on 19445, the self-signed one on 19446, and the client-certificate
// servers on 19447 (TLS 1.2) and 19448 (TLS 1.3), with identity.p12 in /private/tmp/curl-identity-test.
#import <WebKit/WKWebView.h>
#import <Security/Security.h>
#import "cocoa-curl-websocket-page.h"

struct Answers {
    NSURLSessionAuthChallengeDisposition trust { NSURLSessionAuthChallengeUseCredential };
    bool trustCredential { true };
    SecIdentityRef identity { nullptr };
};

struct Seen {
    unsigned trustChallenges { 0 };
    unsigned identityChallenges { 0 };
    bool onMainThread { true };
    bool trustBeforeIdentity { true };
};

static NSString *run(WKWebView *view, WebSocketPageDelegate *delegate, NSString *url, Answers answers, Seen& seen)
{
    seen = { };
    Seen* record = &seen;
    delegate.challengeHandler = ^(NSURLAuthenticationChallenge *challenge, WebSocketChallengeAnswer completion) {
        record->onMainThread &= [NSThread isMainThread];
        NSString *method = challenge.protectionSpace.authenticationMethod;
        if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            ++record->trustChallenges;
            record->trustBeforeIdentity &= !record->identityChallenges;
            completion(answers.trust, answers.trustCredential ? [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] : nil);
            return;
        }
        if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
            ++record->identityChallenges;
            if (answers.identity)
                completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithIdentity:answers.identity certificates:nil persistence:NSURLCredentialPersistenceNone]);
            else
                completion(NSURLSessionAuthChallengeUseCredential, nil);
            return;
        }
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    };
    NSString *script = [NSString stringWithFormat:@"return (await socketEvents('%@', { timeout: 10000 })).events.join(',');", url];
    return [runWebSocketPage(view, @"http://127.0.0.1:18981/", script) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
}

static void expect(const char *what, NSString *events, NSString *expected, const Seen& seen, unsigned trustChallenges, unsigned identityChallenges)
{
    bool passed = [events isEqualToString:expected] && seen.trustChallenges == trustChallenges && seen.identityChallenges == identityChallenges
        && seen.onMainThread && seen.trustBeforeIdentity;
    printf("%s: expected [%s] got [%s] trust challenges=%u identity challenges=%u main=%d %s\n", what, expected.UTF8String, events.UTF8String ?: "(no result)",
        seen.trustChallenges, seen.identityChallenges, seen.onMainThread, passed ? "PASS" : "FAIL");
    webSocketFailures += !passed;
}

// The identity lives in a keychain of the user's whose items any application may use, so the network process can sign
// with it; the keychain is deleted on exit.
static RetainPtr<SecKeychainRef> importIdentity(SecIdentityRef& identity)
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Keychains/curl-websocket-identity-%@.keychain", [[NSUUID UUID] UUIDString]]];
    SecKeychainRef rawKeychain = nullptr;
    if (SecKeychainCreate(path.fileSystemRepresentation, 7, "fixture", false, nullptr, &rawKeychain))
        return nullptr;
    auto keychain = adoptCF(rawKeychain);
    SecAccessRef rawAccess = nullptr;
    if (SecAccessCreate(CFSTR("cocoa-curl-websocket-trust"), nullptr, &rawAccess))
        return keychain;
    auto access = adoptCF(rawAccess);
    CFArrayRef rawACLs = nullptr;
    if (!SecAccessCopyACLList(access.get(), &rawACLs)) {
        auto acls = adoptCF(rawACLs);
        for (CFIndex i = 0; i < CFArrayGetCount(acls.get()); ++i)
            SecACLSetContents((SecACLRef)CFArrayGetValueAtIndex(acls.get(), i), nullptr, CFSTR("cocoa-curl-websocket-trust"), 0);
    }
    NSData *pkcs12 = [NSData dataWithContentsOfFile:@"/private/tmp/curl-identity-test/identity.p12"];
    CFArrayRef rawItems = nullptr;
    if (SecPKCS12Import((__bridge CFDataRef)pkcs12, (__bridge CFDictionaryRef)@{ (id)kSecImportExportPassphrase: @"fixture", (id)kSecImportExportKeychain: (__bridge id)keychain.get(),
        (id)kSecImportExportAccess: (__bridge id)access.get() }, &rawItems))
        return keychain;
    identity = (SecIdentityRef)CFRetain((__bridge CFTypeRef)[(__bridge NSArray *)rawItems objectAtIndex:0][(id)kSecImportItemIdentity]);
    CFRelease(rawItems);
    return keychain;
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WebSocketPageDelegate *delegate = [WebSocketPageDelegate new];
        WKWebView *view = makeWebSocketView(delegate);
        Seen seen;
        NSString *opened = @"open,message:mTLS,close:1000";
        NSString *failed = @"error,close:1006";

        expect("trusted chain: opens with no challenge", run(view, delegate, @"wss://localhost:19445/websocket", { }, seen), opened, seen, 0, 0);
        NSString *untrusted = @"wss://127.0.0.1:19446/websocket";
        expect("untrusted chain, UseCredential with the trust: opens", run(view, delegate, untrusted, { }, seen), opened, seen, 1, 0);
        expect("untrusted chain, UseCredential without a credential: opens, as a load does",
            run(view, delegate, untrusted, { NSURLSessionAuthChallengeUseCredential, false }, seen), opened, seen, 1, 0);
        expect("untrusted chain, default handling: fails",
            run(view, delegate, untrusted, { NSURLSessionAuthChallengePerformDefaultHandling, false }, seen), failed, seen, 1, 0);
        expect("untrusted chain, protection space rejected: fails",
            run(view, delegate, untrusted, { NSURLSessionAuthChallengeRejectProtectionSpace, false }, seen), failed, seen, 1, 0);
        expect("untrusted chain, cancelled: fails",
            run(view, delegate, untrusted, { NSURLSessionAuthChallengeCancelAuthenticationChallenge, false }, seen), failed, seen, 1, 0);

        SecIdentityRef identity = nullptr;
        auto keychain = importIdentity(identity);
        expectTrue("import the client identity", !!identity, nil);
        if (identity) {
            for (NSString *port : @[ @"19447", @"19448" ]) {
                NSString *url = [NSString stringWithFormat:@"wss://127.0.0.1:%@/websocket", port];
                bool tls12 = [port isEqualToString:@"19447"];
                expect(tls12 ? "TLS 1.2 client certificate supplied: opens" : "TLS 1.3 client certificate supplied: opens",
                    run(view, delegate, url, { NSURLSessionAuthChallengeUseCredential, true, identity }, seen), opened, seen, 1, 1);
                expect(tls12 ? "TLS 1.2 no client certificate: refused" : "TLS 1.3 no client certificate: refused",
                    run(view, delegate, url, { }, seen), failed, seen, 1, 1);
            }
            CFRelease(identity);
        }
        if (keychain)
            SecKeychainDelete(keychain.get());

        printf("WebSocket trust: FAILED=%u\n", webSocketFailures);
        return webSocketFailures ? 1 : 0;
    }
}
