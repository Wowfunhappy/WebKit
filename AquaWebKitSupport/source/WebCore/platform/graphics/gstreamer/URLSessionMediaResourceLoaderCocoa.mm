#import "config.h"
#import "URLSessionMediaResourceLoaderCocoa.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)

#import "HTTPHeaderNames.h"
#import "HTTPParsers.h"
#import "HTTPStatusCodes.h"
#import "NetworkLoadMetrics.h"
#import "ParsedContentRange.h"
#import "ResourceError.h"
#import "ResourceRequest.h"
#import "ResourceResponse.h"
#import "SharedBuffer.h"
#import "WebCoreNSURLSession.h"
#import <Foundation/Foundation.h>
#import <wtf/BlockPtr.h>
#import <wtf/HashMap.h>
#import <wtf/MainThread.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/MakeString.h>

namespace WebCore {
class URLSessionMediaResource;
}

// Hands each data task's session callbacks to the client of the resource it was created for. Its table is used on
// the main thread: the session's delegate queue is the main queue, and shutdown() moves there.
@interface WebCoreURLSessionMediaResourceDelegate : NSObject <NSURLSessionDataDelegate> {
@package
    HashMap<NSUInteger, ThreadSafeWeakPtr<WebCore::URLSessionMediaResource>> _resources;
    HashMap<String, uint64_t> _resourceLengths;
    HashMap<NSUInteger, uint64_t> _wholeBodyLengths;
}
- (RefPtr<WebCore::URLSessionMediaResource>)resourceForTask:(NSURLSessionTask *)task;
@end

namespace WebCore {

class URLSessionMediaResource final : public PlatformMediaResource {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(URLSessionMediaResource);
public:
    static Ref<URLSessionMediaResource> create(NSURLSessionDataTask *task, WebCoreNSURLSession *session, WebCoreURLSessionMediaResourceDelegate *delegate)
    {
        return adoptRef(*new URLSessionMediaResource(task, session, delegate));
    }

    ~URLSessionMediaResource()
    {
        [m_task cancel];
    }

    bool didPassAccessControlCheck() const final { return [m_session didPassCORSAccessChecks]; }

    void shutdown() final
    {
        ensureOnMainThread([task = m_task, delegate = m_delegate] {
            delegate->_resources.remove(task.get().taskIdentifier);
            [task cancel];
        });
    }

private:
    URLSessionMediaResource(NSURLSessionDataTask *task, WebCoreNSURLSession *session, WebCoreURLSessionMediaResourceDelegate *delegate)
        : m_task(task)
        , m_session(session)
        , m_delegate(delegate)
    {
    }

    const RetainPtr<NSURLSessionDataTask> m_task;
    const RetainPtr<WebCoreNSURLSession> m_session;
    const RetainPtr<WebCoreURLSessionMediaResourceDelegate> m_delegate;
};

} // namespace WebCore

// The whole resource's length a response states: a range response's Content-Range length, or the length of a whole,
// unencoded body.
static std::optional<uint64_t> resourceLength(const WebCore::ResourceResponse& response)
{
    if (response.httpStatusCode() == WebCore::httpStatus206PartialContent) {
        WebCore::ParsedContentRange contentRange(response.httpHeaderField(WebCore::HTTPHeaderName::ContentRange));
        if (!contentRange.isValid() || contentRange.instanceLength() == WebCore::ParsedContentRange::unknownLength)
            return std::nullopt;
        return contentRange.instanceLength();
    }
    if (response.httpStatusCode() != WebCore::httpStatus200OK || response.httpHeaderFields().contains(WebCore::HTTPHeaderName::ContentEncoding) || response.expectedContentLength() <= 0)
        return std::nullopt;
    return response.expectedContentLength();
}

@implementation WebCoreURLSessionMediaResourceDelegate

- (RefPtr<WebCore::URLSessionMediaResource>)resourceForTask:(NSURLSessionTask *)task
{
    ASSERT(isMainThread());
    auto iterator = _resources.find(task.taskIdentifier);
    if (iterator == _resources.end())
        return nullptr;
    return iterator->value.get();
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    UNUSED_PARAM(session);
    WebCore::ResourceResponse resourceResponse(response);
    if (auto length = resourceLength(resourceResponse))
        _resourceLengths.set(String(dataTask.originalRequest.URL.absoluteString), *length);
    // A whole, unencoded body states the resource's length when it completes, also when no header gives it.
    if (resourceResponse.httpStatusCode() == WebCore::httpStatus200OK && !resourceResponse.httpHeaderFields().contains(WebCore::HTTPHeaderName::ContentEncoding) && ![dataTask.originalRequest valueForHTTPHeaderField:@"Range"])
        _wholeBodyLengths.set(dataTask.taskIdentifier, 0);
    RefPtr resource = [self resourceForTask:dataTask];
    RefPtr client = resource ? resource->client() : nullptr;
    if (!client) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    client->responseReceived(*resource, resourceResponse, [completionHandler = makeBlockPtr(completionHandler)](WebCore::ShouldContinuePolicyCheck shouldContinue) {
        completionHandler(shouldContinue == WebCore::ShouldContinuePolicyCheck::Yes ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    UNUSED_PARAM(session);
    if (auto length = _wholeBodyLengths.find(dataTask.taskIdentifier); length != _wholeBodyLengths.end())
        length->value += data.length;
    RefPtr resource = [self resourceForTask:dataTask];
    if (RefPtr client = resource ? resource->client() : nullptr)
        client->dataReceived(*resource, WebCore::SharedBuffer::create(data));
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    UNUSED_PARAM(session);
    RefPtr resource = [self resourceForTask:task];
    RefPtr client = resource ? resource->client() : nullptr;
    if (!client) {
        completionHandler(nil);
        return;
    }
    client->redirectReceived(*resource, WebCore::ResourceRequest(request), WebCore::ResourceResponse(response), [completionHandler = makeBlockPtr(completionHandler)](WebCore::ResourceRequest&& request) {
        completionHandler(request.isNull() ? nil : request.nsURLRequest(WebCore::HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody));
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    UNUSED_PARAM(session);
    RefPtr resource = [self resourceForTask:task];
    _resources.remove(task.taskIdentifier);
    if (auto length = _wholeBodyLengths.takeOptional(task.taskIdentifier); length && !error)
        _resourceLengths.set(String(task.originalRequest.URL.absoluteString), *length);
    RefPtr client = resource ? resource->client() : nullptr;
    if (!client)
        return;
    if (error)
        client->loadFailed(*resource, WebCore::ResourceError(error));
    else
        client->loadFinished(*resource, WebCore::NetworkLoadMetrics { });
}

@end

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(URLSessionMediaResourceLoader);

Ref<URLSessionMediaResourceLoader> URLSessionMediaResourceLoader::create(Ref<PlatformMediaResourceLoader>&& loader)
{
    return adoptRef(*new URLSessionMediaResourceLoader(WTF::move(loader)));
}

URLSessionMediaResourceLoader::URLSessionMediaResourceLoader(Ref<PlatformMediaResourceLoader>&& loader)
    : m_loader(WTF::move(loader))
    , m_delegate(adoptNS([[WebCoreURLSessionMediaResourceDelegate alloc] init]))
    , m_session(adoptNS([[WebCoreNSURLSession alloc] initWithResourceLoader:m_loader.get() delegate:m_delegate.get() delegateQueue:[NSOperationQueue mainQueue]]))
{
}

URLSessionMediaResourceLoader::~URLSessionMediaResourceLoader()
{
    [m_session invalidateAndCancel];
}

void URLSessionMediaResourceLoader::sendH2Ping(const URL& url, CompletionHandler<void(Expected<Seconds, ResourceError>&&)>&& completionHandler)
{
    m_loader->sendH2Ping(url, WTF::move(completionHandler));
}

Ref<GuaranteedSerialFunctionDispatcher> URLSessionMediaResourceLoader::targetDispatcher()
{
    return m_loader->targetDispatcher();
}

RefPtr<PlatformMediaResource> URLSessionMediaResourceLoader::requestResource(ResourceRequest&& request, LoadOptions)
{
    ASSERT(isMainThread());
    // WebCoreNSURLSession answers a range from the copy of a resource whose server ignored the range only when the
    // range is closed, the form AVFoundation sends. An open range is closed at the resource's length, from a response
    // that states it or a whole body that completed.
    if (auto range = parseRange(request.httpHeaderField(HTTPHeaderName::Range), RangeAllowWhitespace::No); range && range->start && !range->end) {
        auto length = m_delegate->_resourceLengths.find(request.url().string());
        if (length != m_delegate->_resourceLengths.end() && *range->start < length->value)
            request.setHTTPHeaderField(HTTPHeaderName::Range, makeString("bytes="_s, *range->start, '-', length->value - 1));
    }
    RetainPtr task = [m_session dataTaskWithRequest:request.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody)];
    if (!task)
        return nullptr;
    Ref resource = URLSessionMediaResource::create(task.get(), m_session.get(), m_delegate.get());
    m_delegate->_resources.set(task.get().taskIdentifier, resource.get());
    [task resume];
    return resource;
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)
