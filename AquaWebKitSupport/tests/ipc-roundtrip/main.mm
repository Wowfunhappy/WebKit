#include "config.h"
#include "ArgumentCodersCocoa.h"
#include "CoreIPCDDScannerResult.h"
#include "CoreIPCDDSecureActionContext.h"
#include "CoreIPCNSURLRequest.h"
#include "Decoder.h"
#include "Encoder.h"
#include "GeneratedSerializers.h"
#include "MessageNames.h"
#include "ObjCObjectGraph.h"
#include "WKRetainPtr.h"
#include "WKString.h"
#include "WKStringCF.h"
#include "WKType.h"
#import "WKTypeRefWrapper.h"
#include <wtf/MainThread.h>
#import <AppKit/AppKit.h>
#include <pal/spi/cocoa/DataDetectorsCoreSPI.h>
#include <pal/spi/mac/DataDetectorsSPI.h>
#include <pal/mac/DataDetectorsSoftLink.h>
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

@interface DDScannerResult (RoundTrip)
- (NSDictionary *)wk__webKitPropertyListData;
- (instancetype)wk__initWithWebKitPropertyListData:(NSDictionary *)propertyList;
@end

@interface DDActionContext (NativeRoundTrip)
@property BOOL isRightClick;
@property NSRect aimFrame;
@property (copy) NSString *eventTitle;
@property (copy) NSDate *referenceDate;
@property (copy) NSString *authorUUID;
@property (copy) NSString *authorName;
@property (copy) NSString *authorEmailAddress;
@property (copy) NSURL *URL;
@property (copy) NSString *matchedString;
@property (copy) NSString *selectionString;
- (NSDictionary *)wk__webKitPropertyListData;
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

template<typename Wrapper> static RetainPtr<id> wrapperRoundTrip(id object)
{
    Wrapper wrapped(object);
    IPC::Encoder encoder(message, 23);
    encoder << wrapped;
    auto decoder = IPC::Decoder::create(encoder.span(), encoder.releaseAttachments());
    RELEASE_ASSERT(decoder && decoder->messageName() == message && decoder->destinationID() == 23);
    auto decoded = decoder->template decode<Wrapper>();
    RELEASE_ASSERT(decoded && decoder->isValid());
    return decoded->toID();
}

// Every field of the two results' property lists matches, subresults compared the same way; returns the
// number of results compared.
static unsigned assertSameResult(DDScannerResult *before, DDScannerResult *after)
{
    RELEASE_ASSERT([after isKindOfClass:NSClassFromString(@"DDScannerResult")]);
    NSDictionary *beforeList = [before wk__webKitPropertyListData];
    NSDictionary *afterList = [after wk__webKitPropertyListData];
    RELEASE_ASSERT(beforeList[@"AR"] && beforeList[@"T"] && beforeList.count == afterList.count);
    for (NSString *key in beforeList) {
        if (![key isEqualToString:@"SR"])
            RELEASE_ASSERT([beforeList[key] isEqual:afterList[key]]);
    }
    NSArray *beforeSubresults = beforeList[@"SR"];
    NSArray *afterSubresults = afterList[@"SR"];
    RELEASE_ASSERT(beforeSubresults.count == afterSubresults.count);
    unsigned compared = 1;
    for (NSUInteger i = 0; i < beforeSubresults.count; ++i)
        compared += assertSameResult(beforeSubresults[i], afterSubresults[i]);
    return compared;
}

static void assertSameContext(WKDDActionContext *before, WKDDActionContext *after)
{
    RELEASE_ASSERT([after class] == [before class]);
    NSDictionary *beforeList = [before wk__webKitPropertyListData];
    NSDictionary *afterList = [after wk__webKitPropertyListData];
    RELEASE_ASSERT(beforeList.count == afterList.count);
    for (NSString *key in beforeList) {
        if (![key isEqualToString:@"allResults"] && ![key isEqualToString:@"mainResult"])
            RELEASE_ASSERT([beforeList[key] isEqual:afterList[key]]);
    }
    NSArray *beforeResults = beforeList[@"allResults"];
    NSArray *afterResults = afterList[@"allResults"];
    RELEASE_ASSERT(beforeResults.count == afterResults.count);
    for (NSUInteger i = 0; i < beforeResults.count; ++i)
        assertSameResult(beforeResults[i], afterResults[i]);
    RELEASE_ASSERT(!beforeList[@"mainResult"] == !afterList[@"mainResult"]);
    if (beforeList[@"mainResult"])
        assertSameResult(beforeList[@"mainResult"], afterList[@"mainResult"]);
    RELEASE_ASSERT(NSEqualRects(before.highlightFrame, after.highlightFrame) && NSEqualRects(before.aimFrame, after.aimFrame));
    RELEASE_ASSERT(before.immediate == after.immediate && before.isRightClick == after.isRightClick);
}

static RetainPtr<id> objectGraphRoundTrip(id root)
{
    IPC::Encoder encoder(message, 5);
    WebKit::ObjCObjectGraph::encode(encoder, root);
    encoder << true;
    auto decoder = IPC::Decoder::create(encoder.span(), encoder.releaseAttachments());
    RELEASE_ASSERT(decoder && decoder->messageName() == message);
    RetainPtr<id> result;
    RELEASE_ASSERT(WebKit::ObjCObjectGraph::decode(*decoder, result));
    auto trailing = decoder->decode<bool>();
    RELEASE_ASSERT(trailing && *trailing && decoder->isValid());
    return result;
}

static void objectGraphRoundTrips()
{
    RELEASE_ASSERT(!objectGraphRoundTrip(nil));
    puts("PASS ObjCObjectGraph nil root keeps the following field aligned");

    auto string = adoptWK(WKStringCreateWithCFString(CFSTR("wrapped")));
    auto wrapper = adoptNS([[WKTypeRefWrapper alloc] initWithObject:string.get()]);
    NSArray *list = @[@1, @YES, @2.5, @"text", [NSData dataWithBytes:"ab" length:2], [NSDate dateWithTimeIntervalSinceReferenceDate:12345]];
    NSDictionary *body = @{ @"wrapper": wrapper.get(), @"list": list, @"large": @(1ULL << 60), @"nested": @{ @"inner": @[wrapper.get()] } };
    auto decodedRoot = objectGraphRoundTrip(body);
    NSDictionary *decoded = decodedRoot.get();
    RELEASE_ASSERT([decoded isKindOfClass:NSDictionary.class] && decoded.count == body.count);
    RELEASE_ASSERT([decoded[@"list"] isEqual:list] && [decoded[@"large"] isEqual:body[@"large"]]);
    for (WKTypeRefWrapper *decodedWrapper in @[decoded[@"wrapper"], decoded[@"nested"][@"inner"][0]]) {
        RELEASE_ASSERT([decodedWrapper isKindOfClass:WKTypeRefWrapper.class]);
        RELEASE_ASSERT(WKGetTypeID(decodedWrapper.object) == WKStringGetTypeID());
        RELEASE_ASSERT(WKStringIsEqual((WKStringRef)decodedWrapper.object, string.get()));
    }
    puts("PASS ObjCObjectGraph carries nested WKTypeRefWrappers, dates, data and typed numbers");
}

int main()
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    WTF::initializeMainThread();
    objectGraphRoundTrips();
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
        NSString *text = @"Meet at 1 Infinite Loop, Cupertino, CA 95014 on Friday, March 6 at 4 PM, call +1 (408) 555-1234 or visit https://www.apple.com/";
        auto scanner = adoptCF(createScanner(DDScannerType1, 0, nullptr));
        auto query = adoptCF(createQuery(nullptr, (__bridge CFStringRef)text, CFRangeMake(0, text.length)));
        RELEASE_ASSERT(scanner && query && scan(scanner.get(), query.get()));
        auto coreResults = adoptCF(copyResults(scanner.get(), DDScannerCopyResultsOptionsNone));
        RELEASE_ASSERT(coreResults && CFArrayGetCount(coreResults.get()));
        Class scannerClass = NSClassFromString(@"DDScannerResult");
        NSArray *results = [scannerClass resultsFromCoreResults:coreResults.get()];
        RELEASE_ASSERT(results.count);
        unsigned compared = 0;
        for (DDScannerResult *result in results) {
            auto decoded = roundTrip(result);
            RELEASE_ASSERT(CFEqual(getType(result.coreResult), getType(decoded.get().coreResult)));
            CFRange before = getRange(result.coreResult), after = getRange(decoded.get().coreResult);
            RELEASE_ASSERT(before.location == after.location && before.length == after.length);
            compared += assertSameResult(result, decoded.get());
            compared += assertSameResult(result, wrapperRoundTrip<WebKit::CoreIPCDDScannerResult>(result).get());
        }
        // A result whose subresults are the scanned ones, built through the property-list initializer.
        NSDictionary *parentList = @{ @"AR": [NSValue valueWithRange:NSMakeRange(0, text.length)], @"MS": text, @"T": @"Parent", @"SR": results };
        RetainPtr<DDScannerResult> parent = adoptNS((DDScannerResult *)[[scannerClass alloc] wk__initWithWebKitPropertyListData:parentList]);
        RELEASE_ASSERT(parent && [[parent.get() wk__webKitPropertyListData][@"SR"] count] == results.count);
        unsigned nested = assertSameResult(parent.get(), roundTrip(parent.get()).get());
        nested += assertSameResult(parent.get(), wrapperRoundTrip<WebKit::CoreIPCDDScannerResult>(parent.get()).get());
        RELEASE_ASSERT(nested == 2 * (1 + results.count));
        printf("PASS DDScannerResult IPC: %lu native scan results and a result nesting them, %u results compared field by field\n",
            (unsigned long)results.count, compared + nested);
        Class nativeContext = NSClassFromString(@"DDActionContext");
        RELEASE_ASSERT(![nativeContext conformsToProtocol:@protocol(NSSecureCoding)]);
        RetainPtr<WKDDActionContext> context = adoptNS([PAL::allocWKDDActionContextInstance() init]);
        RELEASE_ASSERT([context class] == IPC::getClass<WKDDActionContext>() && [context class] != nativeContext);
        [context setHighlightFrame:NSMakeRect(10, 20, 30, 40)];
        [context setAimFrame:NSMakeRect(1, 2, 3, 4)];
        [context setEventTitle:@"Lunch"];
        [context setReferenceDate:[NSDate dateWithTimeIntervalSinceReferenceDate:400000000]];
        [context setAuthorUUID:@"5D7A3C1E-0000-4000-8000-000000000001:ABPerson"];
        [context setAuthorName:@"Author Name"];
        [context setAuthorEmailAddress:@"author@example.test"];
        [context setURL:[NSURL URLWithString:@"https://context.test/page"]];
        [context setMatchedString:@"1 Infinite Loop"];
        [context setSelectionString:@"selection"];
        [context setAllResults:(__bridge NSArray *)coreResults.get()];
        [context setMainResult:(DDResultRef)CFArrayGetValueAtIndex(coreResults.get(), 0)];
        [context setImmediate:YES];
        [context setIsRightClick:YES];
        RELEASE_ASSERT([[context wk__webKitPropertyListData] count] == 14);
        assertSameContext(context.get(), roundTrip(context.get()).get());
        assertSameContext(context.get(), wrapperRoundTrip<WebKit::CoreIPCDDSecureActionContext>(context.get()).get());
        auto copy = adoptNS([context copy]);
        RELEASE_ASSERT([copy class] == [context class]);
        assertSameContext((WKDDActionContext *)copy.get(), roundTrip((WKDDActionContext *)copy.get()).get());
        puts("PASS DDSecureActionContext IPC: all 14 native fields, results and main result, and of a copy");
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
