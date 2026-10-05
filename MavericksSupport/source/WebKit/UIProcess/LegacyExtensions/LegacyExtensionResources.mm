#import "config.h"
#import "LegacyExtensionResources.h"

#import <Foundation/Foundation.h>
#import <wtf/BlockPtr.h>
#import <wtf/MainThread.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>
#import <wtf/URL.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/Base64.h>

namespace WebKit::LegacyExtensions {

void loadExtensionResource(const URL& url, ResourceCompletionHandler&& completionHandler)
{
    RetainPtr task = [NSURLSession.sharedSession dataTaskWithURL:url.createNSURL().get() completionHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)](NSData *data, NSURLResponse *response, NSError *error) mutable {
        RunLoop::mainSingleton().dispatch([completionHandler = WTF::move(completionHandler), data = RetainPtr { data }, mimeType = String { response.MIMEType }, failed = !!error]() mutable {
            if (failed || !data)
                return completionHandler(std::nullopt, { });
            completionHandler(makeVector(data.get()), WTF::move(mimeType));
        });
    }).get()];
    [task resume];
}

Ref<JSON::Object> fetchedMessage(double fetchID, std::optional<Vector<uint8_t>>&& data, String&& mimeType)
{
    auto message = JSON::Object::create();
    message->setString("t"_s, "fetched"_s);
    message->setDouble("id"_s, fetchID);
    if (data)
        message->setString("data"_s, base64EncodeToString(data->span()));
    if (!mimeType.isNull())
        message->setString("mimeType"_s, mimeType);
    return message;
}

static Function<void(const URL&, ResourceCompletionHandler&&)>& resourceFetcher()
{
    static NeverDestroyed<Function<void(const URL&, ResourceCompletionHandler&&)>> fetcher;
    return fetcher;
}

} // namespace WebKit::LegacyExtensions

// Serves safari-extension:// loads on the run loop of the thread that starts them.
@interface WKLegacyExtensionResourceProtocol : NSURLProtocol
@end

@implementation WKLegacyExtensionResourceProtocol {
    BOOL _stopped;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return [request.URL.scheme caseInsensitiveCompare:@"safari-extension"] == NSOrderedSame;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    RetainPtr<CFRunLoopRef> runLoop = CFRunLoopGetCurrent();
    RetainPtr protocol = self;
    URL url { self.request.URL };
    callOnMainRunLoop([runLoop = WTF::move(runLoop), protocol = WTF::move(protocol), url = WTF::move(url)]() mutable {
        auto& fetch = WebKit::LegacyExtensions::resourceFetcher();
        fetch(url, [runLoop = WTF::move(runLoop), protocol = WTF::move(protocol)](std::optional<Vector<uint8_t>>&& data, String&& mimeType) mutable {
            RetainPtr<NSData> nsData;
            if (data)
                nsData = toNSData(data->span());
            RetainPtr<NSString> nsMIMEType = mimeType.isNull() ? nil : mimeType.createNSString();
            CFRunLoopPerformBlock(runLoop.get(), kCFRunLoopCommonModes, makeBlockPtr([protocol = WTF::move(protocol), nsData = WTF::move(nsData), nsMIMEType = WTF::move(nsMIMEType)] {
                [protocol finishWithData:nsData.get() MIMEType:nsMIMEType.get()];
            }).get());
            CFRunLoopWakeUp(runLoop.get());
        });
    });
}

- (void)finishWithData:(NSData *)data MIMEType:(NSString *)mimeType
{
    if (_stopped)
        return;
    if (!data) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
        return;
    }
    RetainPtr response = adoptNS([[NSURLResponse alloc] initWithURL:self.request.URL MIMEType:mimeType expectedContentLength:data.length textEncodingName:nil]);
    [self.client URLProtocol:self didReceiveResponse:response.get() cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading
{
    _stopped = YES;
}

@end

namespace WebKit::LegacyExtensions {

void serveExtensionResources(Function<void(const URL&, ResourceCompletionHandler&&)>&& fetch)
{
    if (resourceFetcher())
        return;
    resourceFetcher() = WTF::move(fetch);
    [NSURLProtocol registerClass:WKLegacyExtensionResourceProtocol.class];
}

} // namespace WebKit::LegacyExtensions
