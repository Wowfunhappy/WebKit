#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)

#include "PlatformMediaResourceLoader.h"
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS WebCoreNSURLSession;
OBJC_CLASS WebCoreURLSessionMediaResourceDelegate;

namespace WebCore {

// HTTP resources use WebCoreNSURLSession and RangeResponseGenerator. Non-HTTP resources use the
// WebCore media loader with the requested byte window of a whole representation.
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
