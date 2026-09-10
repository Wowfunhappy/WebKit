#include <wtf/Assertions.h>
#include <pal/SessionID.h>
// A private WK2 download is stopped and resumed twice through Safari's actual WebDownload SPI.
#import <Cocoa/Cocoa.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <WebKit/WKHTTPCookieStore.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKDownload.h>
#import <WebKit/WKDownloadDelegate.h>
#import <WebKitLegacy/WebDownload.h>
#include <cstdio>
@interface WebDownload (NativeResumeTest)
- (id)_initWithResumeInformation:(NSDictionary*)information delegate:(id)delegate path:(NSString*)path;
- (NSDictionary*)_resumeInformation;
@end
@interface WKDownload (ProgressTest)
@property(readonly) NSProgress* progress;
@end
static unsigned failures;
static void check(bool condition, const char* message) { if (!condition) { ++failures; printf("FAIL %s\n", message); } }
@interface Probe : NSObject <WKNavigationDelegate, WKDownloadDelegate, NSURLDownloadDelegate> {
@public
    WKWebView* view;
    WKDownload* original;
    WebDownload* resumed;
    NSProgress* observed;
    NSString* path;
    bool stopping;
    bool stoppedLegacy;
    unsigned responses;
    unsigned phase;
    long long offset;
}
- (void)resume:(NSDictionary*)information;
- (void)deadline;
@end
@implementation Probe
- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:18983/private-file?run=%@", [NSUUID UUID].UUIDString]]];
    [request setValue:@"original" forHTTPHeaderField:@"X-Test-Representation"];
    [webView startDownloadUsingRequest:request completionHandler:^(WKDownload* download) {
        original = [download retain];
        original.delegate = self;
        observed = [original.progress retain];
        [observed addObserver:self forKeyPath:@"completedUnitCount" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:nullptr];
    }];
}
- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
    NSLog(@"private page failed: %@", error);
    check(false, "private page navigation");
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)download:(WKDownload*)download decideDestinationUsingResponse:(NSURLResponse*)response suggestedFilename:(NSString*)suggestedFilename completionHandler:(void (^)(NSURL*))completion
{
    check([(NSHTTPURLResponse*)response statusCode] == 200, "initial download has the private cookie");
    completion([NSURL fileURLWithPath:path]);
}
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
    if (stopping || !observed.completedUnitCount)
        return;
    stopping = true;
    [observed removeObserver:self forKeyPath:@"completedUnitCount"];
    [original cancel:^(NSData* data) {
        NSDictionary* modern = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        check([modern isKindOfClass:[NSDictionary class]], "WK2 cancellation produces resume information");
        if (![modern isKindOfClass:[NSDictionary class]]) { CFRunLoopStop(CFRunLoopGetMain()); return; }
        NSMutableDictionary* information = [NSMutableDictionary dictionaryWithDictionary:modern];
        information[@"NSURLDownloadURL"] = modern[@"NSURLSessionDownloadURL"];
        information[@"NSURLDownloadBytesReceived"] = modern[@"NSURLSessionResumeBytesReceived"];
        information[@"WebKitNetworkProcessResumeData"] = data;
        check([information[@"WebKitStorageSessionIdentifier"] unsignedLongLongValue] != PAL::SessionID::defaultSessionID().toUInt64(), "resume retains a non-default session identifier");
        [self resume:information];
    }];
}
- (void)resume:(NSDictionary*)information
{
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    check([information[@"NSURLDownloadBytesReceived"] unsignedLongLongValue] == size, "resume offset equals the closed writer's file length");
    check(size > 0 && size < 2097152, "cancellation retained an incomplete representation");
    ++phase;
    responses = 0;
    offset = -1;
    resumed = [[WebDownload alloc] _initWithResumeInformation:information delegate:self path:path];
    [resumed setDeletesFileUponFailure:NO];
    check(!!resumed, "native WebDownload resume initializer");
    if (!resumed) CFRunLoopStop(CFRunLoopGetMain());
}
- (void)downloadDidBegin:(NSURLDownload*)download
{
    check([download respondsToSelector:@selector(_directoryPath)], "Safari native directory getter exists");
    check(![download performSelector:@selector(_directoryPath)], "resume has no explicitly configured download directory");
}
- (void)download:(NSURLDownload*)download didReceiveResponse:(NSURLResponse*)response
{
    ++responses;
    check([(NSHTTPURLResponse*)response statusCode] == 206, "private resume sent its cookie and representation header");
}
- (void)download:(NSURLDownload*)download willResumeWithResponse:(NSURLResponse*)response fromByte:(long long)byte
{
    check(responses == 1, "resume follows the response callback");
    offset = byte;
}
- (void)download:(NSURLDownload*)download didReceiveDataOfLength:(NSUInteger)length
{
    check(responses == 1 && offset > 0, "data follows response and resume callbacks");
    if (phase != 1 || stoppedLegacy)
        return;
    stoppedLegacy = true;
    [download cancel];
    NSDictionary* information = [[(WebDownload*)download _resumeInformation] retain];
    check(!!information[@"WebKitNetworkProcessResumeData"], "native synchronous cancel preserves NetworkProcess ownership");
    [self resume:information];
    [information release];
}
- (void)downloadDidFinish:(id)download
{
    check(phase == 2, "download finished only after both resumes");
    NSData* data = [NSData dataWithContentsOfFile:path];
    check(data.length == 2097152, "complete representation length");
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    bool matches = data.length == 2097152;
    for (NSUInteger i = 0; matches && i < data.length; ++i) matches = bytes[i] == (i & 255);
    check(matches, "complete representation byte content");
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)download:(id)download didFailWithError:(NSError*)error
{
    NSLog(@"native download failed: %@", error);
    check(false, "native resumed download completed");
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)download:(WKDownload*)download didFailWithError:(NSError*)error resumeData:(NSData*)data
{
    NSLog(@"WK2 download failed: %@", error);
    check(false, "WK2 private download completed");
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)deadline
{
    check(false, "download owner test deadline");
    CFRunLoopStop(CFRunLoopGetMain());
}
@end
int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        Probe* probe = [Probe new];
        char directory[] = "/private/tmp/curl-network-resume-XXXXXX";
        RELEASE_ASSERT(mkdtemp(directory));
        probe->path = [[[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"private.bin"] retain];
        WKWebViewConfiguration* configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        // An ephemeral session takes the account's cookie accept policy as its own, and the download
        // this test follows is one the server only serves to a request carrying its cookie, so the
        // session is told the policy the test needs instead of reading the machine's.
        [configuration.websiteDataStore.httpCookieStore setCookiePolicy:WKCookiePolicyAllow completionHandler:nil];
        probe->view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
        probe->view.navigationDelegate = probe;
        [probe->view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:18983/private-page"]]];
        NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:60 target:probe selector:@selector(deadline) userInfo:nil repeats:NO];
        CFRunLoopRun();
        [timer invalidate];
        printf("Cocoa curl NetworkProcess/native private resume: FAILED=%u path=%s\n", failures, probe->path.fileSystemRepresentation);
    }
    return failures ? 1 : 0;
}
