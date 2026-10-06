// An identity whose private key the network half cannot reach: the load cannot succeed, and must reach
// the client as a failure callback carrying an error rather than finishing, blank, or hanging.
#import <Cocoa/Cocoa.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <WebKit/WKNavigationDelegate.h>
#import <Security/Security.h>
#include <cstdio>
@interface _WKWebsiteDataStoreConfiguration : NSObject
- (instancetype)initNonPersistentConfiguration;
@property BOOL allowsServerPreconnect;
@end
@interface WKWebsiteDataStore (IdentityProbeConfiguration)
- (instancetype)_initWithConfiguration:(_WKWebsiteDataStoreConfiguration*)configuration;
@end
enum class Outcome { None, Finished, Failed };
static unsigned failures;
static Outcome outcome;
static bool haveNavigationError;
static long navigationErrorCode;
static void check(bool value, const char* message) { if (!value) { ++failures; printf("FAIL %s\n", message); } }
@interface IdentityProbe : NSObject <WKNavigationDelegate> {
@public
    SecIdentityRef identity;
    unsigned identityChallenges;
}
- (void)deadline;
@end
@implementation IdentityProbe
- (void)webView:(WKWebView*)view didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completion
{
    NSString* method = challenge.protectionSpace.authenticationMethod;
    printf("WK2 challenge method=%s previousFailures=%ld\n", method.UTF8String, (long)challenge.previousFailureCount);
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
        return;
    }
    if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
        ++identityChallenges;
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithIdentity:identity certificates:nil persistence:NSURLCredentialPersistenceNone]);
        return;
    }
    check(false, "expected TLS challenge type");
    completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)webView:(WKWebView*)view didFinishNavigation:(WKNavigation*)navigation
{
    outcome = Outcome::Finished;
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)recordFailure:(NSError*)error
{
    printf("WK2 identity navigation failed: %s %ld\n", error.domain.UTF8String, (long)error.code);
    outcome = Outcome::Failed;
    haveNavigationError = !!error;
    navigationErrorCode = error.code;
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)webView:(WKWebView*)view didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error { [self recordFailure:error]; }
- (void)webView:(WKWebView*)view didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error { [self recordFailure:error]; }
- (void)deadline { CFRunLoopStop(CFRunLoopGetMain()); }
@end

// Drives one load with |identity| selected, and answers how many identity decisions it took.
static unsigned runProbe(SecIdentityRef identity, int port)
{
    outcome = Outcome::None;
    haveNavigationError = false;
    navigationErrorCode = 0;
    IdentityProbe* probe = [IdentityProbe new];
    probe->identity = identity;
    WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
    // This probe counts the selected-identity exchange for one connection; preconnect has its own suite.
    _WKWebsiteDataStoreConfiguration* storeConfiguration = [[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration];
    storeConfiguration.allowsServerPreconnect = NO;
    configuration.websiteDataStore = [[WKWebsiteDataStore alloc] _initWithConfiguration:storeConfiguration];
    WKWebView* view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
    view.navigationDelegate = probe;
    [view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://127.0.0.1:%d/client-certificate", port]]]];
    NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:60 target:probe selector:@selector(deadline) userInfo:nil repeats:NO];
    CFRunLoopRun();
    [timer invalidate];
    return probe->identityChallenges;
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        // ec-identity.p12 is the fixture run.sh does not import anywhere, so this key exists only in the
        // keychain created below and nowhere the NetworkProcess can reach once that keychain is gone.
        NSData* data = [NSData dataWithContentsOfFile:@"/private/tmp/curl-identity-test/ec-identity.p12"];
        check(!!data, "read the identity fixture");
        NSString* directory = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
        NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"curl-refused-identity-%@.keychain", [[NSUUID UUID] UUIDString]]];
        SecKeychainRef keychain = nullptr;
        OSStatus status = data ? SecKeychainCreate(path.fileSystemRepresentation, 7, "fixture", false, nullptr, &keychain) : errSecParam;
        check(!status && keychain, "create the isolated keychain");
        if (status || !keychain) {
            printf("Cocoa curl WK2 refused identity: FAILED=%u\n", failures);
            return 1;
        }
        CFArrayRef items = nullptr;
        status = SecPKCS12Import((CFDataRef)data, (CFDictionaryRef)@{ (id)kSecImportExportPassphrase: @"fixture", (id)kSecImportExportKeychain: (id)keychain }, &items);
        check(!status && items && CFArrayGetCount(items), "import the identity into the isolated keychain");
        if (!status && items && CFArrayGetCount(items)) {
            // Deleting the keychain leaves the selected identity's private key resolvable nowhere, so
            // the NetworkProcess receives a client-certificate credential it cannot sign with.
            check(!SecKeychainDelete(keychain), "delete the isolated keychain");
            unsigned identityChallenges = runProbe((SecIdentityRef)[(NSArray*)items objectAtIndex:0][(id)kSecImportItemIdentity], 19447);
            check(identityChallenges >= 1, "the load asked the client for an identity");
            check(outcome != Outcome::None, "a load that cannot use its identity ends rather than hanging");
            check(outcome != Outcome::Finished, "a load that cannot use its identity does not report success");
            check(outcome == Outcome::Failed && haveNavigationError && navigationErrorCode, "the client is told the load failed, with an error");
            CFRelease(items);
        } else
            SecKeychainDelete(keychain);
        CFRelease(keychain);
        printf("Cocoa curl WK2 refused identity: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
