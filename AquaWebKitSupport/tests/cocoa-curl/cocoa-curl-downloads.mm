// Exercises the real WebDownload ABI, including Safari's private resume initializer.
#import <Foundation/Foundation.h>
#import <WebKitLegacy/WebDownload.h>
#import <WebCore/NetworkStorageSession.h>
#import <WebCore/CocoaCurlTransfer.h>
#import <WebCore/ResourceRequest.h>
#import <pal/SessionID.h>
#import <wtf/MainThread.h>
#import <wtf/ProcessPrivilege.h>
#include <cstdio>

@interface WebDownload (CurlResumeTest)
- (id)_initWithResumeInformation:(NSDictionary *)information delegate:(id)delegate path:(NSString *)path;
- (NSDictionary *)_resumeInformation;
@end

static unsigned failures;
static void check(bool result, const char *message)
{
    if (!result) {
        ++failures;
        printf("FAIL %s\n", message);
    }
}

@interface DownloadTest : NSObject <NSURLDownloadDelegate> {
@public
    NSString *path;
    NSDictionary *resume;
    NSUInteger received;
    long long resumedAt;
    NSInteger errorCode;
    BOOL stop;
    BOOL finished;
    BOOL receivedResponse;
    BOOL authenticating;
    NSUInteger redirects;
}
@end
@implementation DownloadTest
- (void)dealloc { [path release]; [resume release]; [super dealloc]; }
- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response { receivedResponse = YES; }
- (NSURLRequest *)download:(NSURLDownload *)download willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response
{
    if (response)
        ++redirects;
    return request;
}
- (void)download:(NSURLDownload *)download willResumeWithResponse:(NSURLResponse *)response fromByte:(long long)offset { resumedAt = offset; receivedResponse = YES; }
- (void)download:(NSURLDownload *)download decideDestinationWithSuggestedFilename:(NSString *)filename
{
    check(receivedResponse, "response callback precedes destination selection");
    [download setDestination:path allowOverwrite:YES];
}
- (void)download:(NSURLDownload *)download didReceiveDataOfLength:(NSUInteger)length
{
    received += length;
    if (stop && received >= 65536) {
        [download cancel];
        resume = [[(WebDownload *)download _resumeInformation] retain];
        check(resume != nil, "cancelled transfer has resume information");
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
}
- (void)download:(NSURLDownload *)download didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    check(authenticating, "only the auth fixture challenges");
    check([[challenge protectionSpace].authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic], "Basic challenge has native authentication method");
    check([[challenge protectionSpace].realm isEqualToString:@"curl download fixture"], "challenge preserves realm");
    [[challenge sender] useCredential:[NSURLCredential credentialWithUser:@"curl-test" password:@"correct-password" persistence:NSURLCredentialPersistenceNone] forAuthenticationChallenge:challenge];
}
- (void)downloadDidFinish:(NSURLDownload *)download { finished = YES; CFRunLoopStop(CFRunLoopGetCurrent()); }
- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error { errorCode = error.code; printf("download error %ld\n", (long)error.code); CFRunLoopStop(CFRunLoopGetCurrent()); }
@end

static void checkBody(NSString *path)
{
    NSData *body = [NSData dataWithContentsOfFile:path];
    bool correct = body.length == 2097152;
    const uint8_t *bytes = static_cast<const uint8_t *>(body.bytes);
    for (NSUInteger i = 0; correct && i < body.length; ++i)
        correct = bytes[i] == (i & 255);
    check(correct, "download file matches every byte of the 2 MiB representation");
}

static void checkCachedRedirect()
{
    WebCore::NetworkStorageSession storage(PAL::SessionID::defaultSessionID(), nullptr, nullptr);
    NSString *base = [@"http://127.0.0.1:18981/cache/download-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
    NSURLRequest *redirect = [NSURLRequest requestWithURL:[NSURL URLWithString:base] cachePolicy:NSURLRequestReturnCacheDataDontLoad timeoutInterval:10];
    NSURLRequest *target = [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"-target"]] cachePolicy:NSURLRequestReturnCacheDataDontLoad timeoutInterval:10];
    NSData *body = [@"cached download" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc] initWithURL:redirect.URL statusCode:307 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Location": target.URL.absoluteString }];
    NSHTTPURLResponse *targetResponse = [[NSHTTPURLResponse alloc] initWithURL:target.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"text/plain", @"Content-Length": @"15" }];
    NSCachedURLResponse *redirectEntry = [[NSCachedURLResponse alloc] initWithResponse:redirectResponse data:[NSData data]];
    NSCachedURLResponse *targetEntry = [[NSCachedURLResponse alloc] initWithResponse:targetResponse data:body];
    WebCore::ResourceRequest redirectRequest(redirect);
    WebCore::ResourceRequest targetRequest(target);
    WebCore::storeCocoaCurlCachedResponse(&storage, redirectEntry, redirectRequest);
    WebCore::storeCocoaCurlCachedResponse(&storage, targetEntry, targetRequest);
    check(WebCore::lookUpCocoaCurlCachedResponse(&storage, redirectRequest).answer == WebCore::CocoaCurlCacheAnswer::UseCached,
        "cached redirect fixture is available");
    check(WebCore::lookUpCocoaCurlCachedResponse(&storage, targetRequest).answer == WebCore::CocoaCurlCacheAnswer::UseCached,
        "cached redirect target fixture is available");
    DownloadTest *test = [DownloadTest new];
    test->path = [@"/private/tmp/curl-legacy-download-tests/cached-redirect" retain];
    WebDownload *download = [[WebDownload alloc] initWithRequest:redirect delegate:test];
    if (!test->finished && !test->errorCode)
        CFRunLoopRun();
    check(test->finished && !test->errorCode && test->redirects == 1, "cached redirect follows download delegate policy");
    check([[NSData dataWithContentsOfFile:test->path] isEqualToData:body], "cached redirect saves the target body");
    [download release];
    [test release];
    WebCore::removeCocoaCurlCachedResponse(&storage, redirectRequest);
    WebCore::removeCocoaCurlCachedResponse(&storage, targetRequest);
    [redirectEntry release];
    [targetEntry release];
    [redirectResponse release];
    [targetResponse release];
}

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
        WebCore::NetworkStorageSession::permitProcessToUseCookieAPI(true);
        checkCachedRedirect();
        for (NSString *name in @[@"file", @"ignore-range", @"invalid-range", @"changed-etag", @"compressed-range", @"short-range", @"basic"]) {
            printf("CASE %s\n", name.UTF8String);
            DownloadTest *first = [DownloadTest new];
            first->path = [[@"/private/tmp/curl-legacy-download-tests/" stringByAppendingString:name] retain];
            first->stop = ![name isEqualToString:@"basic"];
            first->authenticating = !first->stop;
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:[@"http://127.0.0.1:18982/" stringByAppendingString:name]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
            WebDownload *download = [[WebDownload alloc] initWithRequest:request delegate:first];
            [download setDeletesFileUponFailure:NO];
            CFRunLoopRun();
            if (!first->stop) {
                check(first->finished && !first->errorCode, "HTTP-authenticated download completes");
                checkBody(first->path);
            } else if (first->resume) {
                auto partialLength = [[NSData dataWithContentsOfFile:first->path] length];
                check([[first->resume objectForKey:@"NSURLDownloadBytesReceived"] unsignedLongLongValue] == partialLength, "resume offset equals the written file length");
                DownloadTest *second = [DownloadTest new];
                second->path = [first->path retain];
                second->resumedAt = -1;
                WebDownload *resumed = [[WebDownload alloc] _initWithResumeInformation:first->resume delegate:second path:first->path];
                [resumed setDeletesFileUponFailure:NO];
                CFRunLoopRun();
                if ([name isEqualToString:@"invalid-range"] || [name isEqualToString:@"changed-etag"] || [name isEqualToString:@"compressed-range"]) {
                    check(second->errorCode == NSURLErrorBadServerResponse && !second->finished, "an inconsistent range, validator or content encoding fails without completion");
                    check([[NSData dataWithContentsOfFile:first->path] length] == partialLength, "a rejected range never appends bytes");
                } else if ([name isEqualToString:@"short-range"]) {
                    check(second->errorCode == NSURLErrorNetworkConnectionLost && !second->finished, "a range ending before the representation ends cannot complete the download");
                    check([[NSData dataWithContentsOfFile:first->path] length] == 1048576, "partial range retains only the actually delivered prefix");
                } else {
                    check(second->finished && !second->errorCode, "resumed download completes");
                    check(second->resumedAt == ([name isEqualToString:@"ignore-range"] ? 0 : partialLength), "willResume reports the actual continuation offset");
                    checkBody(second->path);
                }
                [resumed release];
                [second release];
            }
            [download release];
            [first release];
        }
        // A download whose body the connection close delimits lands the whole representation; one cut
        // short of a declared length fails instead of leaving a truncated file behind as a success.
        for (NSString *name in @[@"close-delimited", @"short-length"]) {
            printf("CASE framing/%s\n", name.UTF8String);
            BOOL delimited = [name isEqualToString:@"close-delimited"];
            DownloadTest *test = [DownloadTest new];
            test->path = [[@"/private/tmp/curl-legacy-download-tests/framing-" stringByAppendingString:name] retain];
            [[NSFileManager defaultManager] removeItemAtPath:test->path error:nil];
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:[@"https://127.0.0.1:19449/" stringByAppendingString:name]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
            WebDownload *download = [[WebDownload alloc] initWithRequest:request delegate:test];
            [download setDeletesFileUponFailure:NO];
            CFRunLoopRun();
            if (delimited) {
                check(test->finished && !test->errorCode, "a close-delimited download completes");
                check([[NSData dataWithContentsOfFile:test->path] length] == 5, "a close-delimited download lands every delivered byte");
            } else {
                check(test->errorCode == NSURLErrorNetworkConnectionLost && !test->finished, "a download cut short of its declared length fails");
                // deletesFileUponFailure is off, so what the failure left behind is on disk to be read:
                // the bytes that did arrive, and never the whole representation the length promised.
                NSData *partial = [NSData dataWithContentsOfFile:test->path];
                check(partial && [partial length] == 5, "a failed download keeps only the bytes that arrived");
            }
            [download release];
            [test release];
        }
        printf("WebDownload curl: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
