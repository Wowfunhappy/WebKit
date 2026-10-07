#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)

#include "PlatformMediaResourceLoader.h"
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS WebCoreNSURLSession;
OBJC_CLASS WebCoreURLSessionMediaResourceDelegate;

namespace WebCore {

// The media loader the GStreamer player's sources use on Cocoa. It loads through a WebCoreNSURLSession over the
// player's media resource loader, the session Cocoa's media engine loads through, so each resource keeps that
// session's contract: a closed byte range answered with the whole resource is served from one in-memory copy
// by RangeResponseGenerator.
class URLSessionMediaResourceLoader final
    : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<URLSessionMediaResourceLoader, WTF::DestructionThread::Main>
    , public PlatformMediaResourceLoader {
    WTF_MAKE_TZONE_ALLOCATED(URLSessionMediaResourceLoader);
public:
    static Ref<URLSessionMediaResourceLoader> create(Ref<PlatformMediaResourceLoader>&&);
    ~URLSessionMediaResourceLoader();

    void ref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    void deref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }
    ThreadSafeWeakPtrControlBlock& controlBlock() const final { return ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::controlBlock(); }
    uint32_t weakRefCount() const final { return ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::weakRefCount(); }

    void sendH2Ping(const URL&, CompletionHandler<void(Expected<Seconds, ResourceError>&&)>&&) final;
    Ref<GuaranteedSerialFunctionDispatcher> targetDispatcher() final;
    RefPtr<PlatformMediaResource> requestResource(ResourceRequest&&, LoadOptions) final;

private:
    explicit URLSessionMediaResourceLoader(Ref<PlatformMediaResourceLoader>&&);

    const Ref<PlatformMediaResourceLoader> m_loader;
    const RetainPtr<WebCoreURLSessionMediaResourceDelegate> m_delegate;
    RetainPtr<WebCoreNSURLSession> m_session;
};

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)
