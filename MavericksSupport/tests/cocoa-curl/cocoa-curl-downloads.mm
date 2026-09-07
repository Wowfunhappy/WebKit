// Exercises the real WebDownload ABI, including Safari's private resume initializer.
#import <Foundation/Foundation.h>
#import <WebKitLegacy/WebDownload.h>
#import <WebCore/NetworkStorageSession.h>
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
}
@end
@implementation DownloadTest
- (void)dealloc { [path release]; [resume release]; [super dealloc]; }
- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response { receivedResponse = YES; }
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

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        setProcessPrivileges({ ProcessPrivilege::CanAccessRawCookies, ProcessPrivilege::CanAccessCredentials });
        WebCore::NetworkStorageSession::permitProcessToUseCookieAPI(true);
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
        printf("WebDownload curl: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
