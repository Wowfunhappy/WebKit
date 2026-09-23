#include "config.h"
#include "ArgumentCodersCocoa.h"
#include "CoreIPCNSURLRequest.h"
#include "CoreIPCSecureCoding.h"
#include "Decoder.h"
#include "Encoder.h"
#include "GeneratedSerializers.h"
#include "MessageNames.h"
#include <wtf/MainThread.h>
#import <AppKit/AppKit.h>
#include <pal/spi/cocoa/DataDetectorsCoreSPI.h>
#include <pal/spi/mac/DataDetectorsSPI.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdio.h>

@interface NSURLRequest (RoundTrip)
- (NSDictionary *)wk__webKitPropertyListData;
- (CFTypeRef)_CFURLRequest;
- (instancetype)_initWithCFURLRequest:(CFTypeRef)request;
- (void)setRequestPriority:(long)priority;
- (void)setContentDispositionEncodingFallbackArray:(NSArray *)encodings;
- (void)setPreventsIdleSystemSleep:(BOOL)value;
@end

@interface DDActionContext (NativeRoundTrip)
@property BOOL isRightClick;
@end

static constexpr auto message = IPC::MessageName::AuthenticationManager_CompleteAuthenticationChallenge;

static RetainPtr<NSURLRequest> requestRoundTrip(NSURLRequest *request)
{
    NSDictionary *before = [request wk__webKitPropertyListData];
    RELEASE_ASSERT(before && !before[@"body"] && !before[@"bodyParts"]);
    WebKit::CoreIPCNSURLRequest wrapped(request);
    IPC::Encoder encoder(message, 73);
    encoder << wrapped;
    auto decoder = IPC::Decoder::create(encoder.span(), encoder.releaseAttachments());
    RELEASE_ASSERT(decoder && decoder->messageName() == message && decoder->destinationID() == 73);
    auto decoded = decoder->decode<WebKit::CoreIPCNSURLRequest>();
    RELEASE_ASSERT(decoded && decoder->isValid());
    auto object = decoded->toID();
    NSURLRequest *result = (NSURLRequest *)object.get();
    NSDictionary *after = [result wk__webKitPropertyListData];
    for (NSString *key in before) {
        if (![before[key] isEqual:after[key]])
            NSLog(@"field %@: %@ -> %@", key, before[key], after[key]);
        RELEASE_ASSERT([before[key] isEqual:after[key]]);
    }
    RELEASE_ASSERT([before isEqual:after]);
    RELEASE_ASSERT([request class] == [result class]);
    RELEASE_ASSERT([request isKindOfClass:NSMutableURLRequest.class] == [result isKindOfClass:NSMutableURLRequest.class]);
    RELEASE_ASSERT([before[@"isMutable"] isEqual:after[@"isMutable"]]);
    printf("PASS NSURLRequest IPC: %lu fields, class %s, mutable=%d\n", (unsigned long)before.count,
        class_getName([result class]), [after[@"isMutable"] boolValue]);
    return retainPtr(result);
}

static void siteForCookiesRoundTrip(NSURL *site, const char *name)
{
    NSString *key = @"_kCFHTTPCookiePolicyPropertySiteForCookies";
    auto request = adoptNS([[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://request.test/popup"]]);
    [request setHTTPMethod:@"POST"];
    [NSURLProtocol setProperty:@YES forKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation" inRequest:request.get()];
    if (site)
        [NSURLProtocol setProperty:site forKey:key inRequest:request.get()];
    auto immutable = adoptNS([[NSURLRequest alloc] _initWithCFURLRequest:[request _CFURLRequest]]);
    for (NSURLRequest *source in @[request.get(), immutable.get()]) {
        auto result = requestRoundTrip(source);
        id value = [NSURLProtocol propertyForKey:key inRequest:result.get()];
        if (site) {
            RELEASE_ASSERT([value isKindOfClass:NSURL.class]);
            RELEASE_ASSERT([[value absoluteString] isEqualToString:[site absoluteString]]);
        } else
            RELEASE_ASSERT(!value);
        RELEASE_ASSERT([[NSURLProtocol propertyForKey:@"_kCFHTTPCookiePolicyPropertyIsTopLevelNavigation" inRequest:result.get()] boolValue]);
        RELEASE_ASSERT([[result HTTPMethod] isEqualToString:@"POST"]);
    }
    printf("PASS SameSite NSURLRequest IPC: %s, mutable and immutable POST\n", name);
}

template<typename T> static RetainPtr<T> roundTrip(T *object)
{
    IPC::Encoder encoder(message, 19);
    encoder << retainPtr(object);
    auto decoder = IPC::Decoder::create(encoder.span(), encoder.releaseAttachments());
    RELEASE_ASSERT(decoder && decoder->messageName() == message && decoder->destinationID() == 19);
    auto result = decoder->decode<RetainPtr<T>>();
    RELEASE_ASSERT(result && *result && decoder->isValid());
    RELEASE_ASSERT([result->get() isKindOfClass:IPC::getClass<T>()]);
    return WTF::move(*result);
}

int main()
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    WTF::initializeMainThread();
    @autoreleasepool {
        auto request = adoptNS([[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://request.test/path?q=1"]
            cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:17]);
        [request setHTTPMethod:@"POST"];
        [request addValue:@"one" forHTTPHeaderField:@"X-Multi"];
        [request addValue:@"two" forHTTPHeaderField:@"X-Multi"];
        [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        [request setMainDocumentURL:[NSURL URLWithString:@"https://top.test/"]];
        [request setHTTPShouldHandleCookies:NO];
        [request setHTTPShouldUsePipelining:YES];
        [request setAllowsCellularAccess:NO];
        [request setNetworkServiceType:NSURLNetworkServiceTypeBackground];
        [request setRequestPriority:3];
        [request setPreventsIdleSystemSleep:YES];
        [request setContentDispositionEncodingFallbackArray:@[@(NSWindowsCP1252StringEncoding), @(NSUTF8StringEncoding)]];
        [NSURLProtocol setProperty:@"partition.test" forKey:@"_kCFURLCachePartitionKey" inRequest:request.get()];
        [NSURLProtocol setProperty:@YES forKey:@"appFlag" inRequest:request.get()];
        [NSURLProtocol setProperty:@42 forKey:@"appNumber" inRequest:request.get()];
        [NSURLProtocol setProperty:[@"payload" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"appData" inRequest:request.get()];
        requestRoundTrip(request.get());
        auto immutable = adoptNS([[NSURLRequest alloc] _initWithCFURLRequest:[request _CFURLRequest]]);
        RELEASE_ASSERT(![immutable isKindOfClass:NSMutableURLRequest.class]);
        requestRoundTrip(immutable.get());
        requestRoundTrip([NSURLRequest requestWithURL:[NSURL fileURLWithPath:@"/tmp/request-roundtrip.html"]]);
        auto materialized = adoptNS([[NSMutableURLRequest alloc] initWithURL:[NSURL fileURLWithPath:@"/tmp/materialized.html"]]);
        [materialized setRequestPriority:-1];
        requestRoundTrip(materialized.get());
        siteForCookiesRoundTrip([NSURL URLWithString:@"https://request.test/"], "same-site URL");
        NSURL *crossSite = [NSURL URLWithString:@""];
        RELEASE_ASSERT(crossSite);
        siteForCookiesRoundTrip(crossSite, "empty cross-site URL");
        siteForCookiesRoundTrip(nil, "unspecified site");

        void *core = dlopen("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore", RTLD_LAZY);
        void *ui = dlopen("/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors", RTLD_LAZY);
        RELEASE_ASSERT(core && ui);
        auto createScanner = (decltype(&DDScannerCreate))dlsym(core, "DDScannerCreate");
        auto createQuery = (decltype(&DDScanQueryCreateFromString))dlsym(core, "DDScanQueryCreateFromString");
        auto scan = (decltype(&DDScannerScanQuery))dlsym(core, "DDScannerScanQuery");
        auto copyResults = (decltype(&DDScannerCopyResultsWithOptions))dlsym(core, "DDScannerCopyResultsWithOptions");
        auto getRange = (decltype(&DDResultGetRange))dlsym(core, "DDResultGetRange");
        auto getType = (decltype(&DDResultGetType))dlsym(core, "DDResultGetType");
        RELEASE_ASSERT(createScanner && createQuery && scan && copyResults && getRange && getType);
        NSString *text = @"Call +1 (408) 555-1234 or visit https://www.apple.com/";
        auto scanner = adoptCF(createScanner(DDScannerType1, 0, nullptr));
        auto query = adoptCF(createQuery(nullptr, (__bridge CFStringRef)text, CFRangeMake(0, text.length)));
        RELEASE_ASSERT(scanner && query && scan(scanner.get(), query.get()));
        auto coreResults = adoptCF(copyResults(scanner.get(), DDScannerCopyResultsOptionsNone));
        RELEASE_ASSERT(coreResults && CFArrayGetCount(coreResults.get()));
        Class scannerClass = NSClassFromString(@"DDScannerResult");
        NSArray *results = [scannerClass resultsFromCoreResults:coreResults.get()];
        RELEASE_ASSERT(results.count);
        for (DDScannerResult *result in results) {
            auto decoded = roundTrip(result);
            RELEASE_ASSERT(CFEqual(getType(result.coreResult), getType(decoded.get().coreResult)));
            CFRange before = getRange(result.coreResult), after = getRange(decoded.get().coreResult);
            RELEASE_ASSERT(before.location == after.location && before.length == after.length);
        }
        printf("PASS DDScannerResult IPC: %lu native scan results\n", (unsigned long)results.count);
        IPC::Encoder wrongClassEncoder(message, 19);
        wrongClassEncoder << retainPtr((DDScannerResult *)results[0]);
        auto wrongClassDecoder = IPC::Decoder::create(wrongClassEncoder.span(), wrongClassEncoder.releaseAttachments());
        RELEASE_ASSERT(wrongClassDecoder && wrongClassDecoder->messageName() == message);
        auto present = wrongClassDecoder->decode<bool>();
        RELEASE_ASSERT(present && *present);
        auto rejected = wrongClassDecoder->decodeWithAllowedClasses<DDScannerResult>({ IPC::getClass<WKDDActionContext>() });
        RELEASE_ASSERT(!rejected || !*rejected);
        puts("PASS Data Detectors rejects a mismatched root-class allowlist");
        IPC::Encoder scalarEncoder(message, 19);
        scalarEncoder << true << std::optional(WebKit::CoreIPCSecureCoding(@42));
        auto scalarDecoder = IPC::Decoder::create(scalarEncoder.span(), scalarEncoder.releaseAttachments());
        RELEASE_ASSERT(scalarDecoder && scalarDecoder->messageName() == message);
        RELEASE_ASSERT(!scalarDecoder->decode<RetainPtr<DDScannerResult>>());
        puts("PASS Data Detectors rejects an implicitly allowed NSNumber root");
        auto context = adoptNS([(DDActionContext *)[NSClassFromString(@"DDActionContext") alloc] init]);
        [context setHighlightFrame:NSMakeRect(10, 20, 30, 40)];
        [context setAllResults:(__bridge NSArray *)coreResults.get()];
        [context setMainResult:(DDResultRef)CFArrayGetValueAtIndex(coreResults.get(), 0)];
        [context setImmediate:YES];
        [context setIsRightClick:YES];
        auto back = roundTrip(context.get());
        RELEASE_ASSERT(NSEqualRects(context.get().highlightFrame, back.get().highlightFrame));
        RELEASE_ASSERT(context.get().immediate == back.get().immediate);
        RELEASE_ASSERT(context.get().isRightClick == back.get().isRightClick);
        RELEASE_ASSERT(context.get().allResults.count == back.get().allResults.count);
        RELEASE_ASSERT(CFEqual(getType(context.get().mainResult), getType(back.get().mainResult)));
        puts("PASS DDActionContext IPC: frame, mode, results and main result");
    }
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        @autoreleasepool {
            auto request = adoptNS([[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://request.test/after-pool"]]);
            [NSURLProtocol setProperty:@"survives pool drain" forKey:@"appString" inRequest:request.get()];
            requestRoundTrip(request.get());
        }
    }
    puts("PASS request protocol-key filtering across autorelease pools");

}
