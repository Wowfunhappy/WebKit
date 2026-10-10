// The loads WebKit 1 makes in its own process, as Safari 7 extensions' webRequest sees them. WebKit installs an
// interceptor in the Safari process; WebKit 1's loaders tell it of each load where they hand a request to
// the network, receive a redirect, a response or an authentication challenge, and finish. Each intercept
// returns true when the interceptor has taken the load's continuation.

#pragma once

#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/RefCounted.h>

namespace WebCore {

class AuthenticationChallenge;
class Document;
class FrameLoader;
class LocalFrame;
class ResourceError;
class ResourceHandle;
class ResourceLoader;
class ResourceRequest;
class ResourceResponse;
struct FetchOptions;

class WEBCORE_EXPORT LegacyLoadInterceptor {
public:
    static LegacyLoadInterceptor* NODELETE singleton();
    static void setSingleton(LegacyLoadInterceptor*);

    virtual ~LegacyLoadInterceptor();

    // A ResourceLoader's network load. The interceptor resumes a load it takes by entering the loader again.
    virtual bool interceptStart(ResourceLoader&) = 0;
    virtual bool interceptRedirection(ResourceLoader&, ResourceRequest&, ResourceResponse& redirectResponse, CompletionHandler<void(ResourceRequest&&)>&) = 0;
    virtual bool interceptResponse(ResourceLoader&, ResourceResponse&, CompletionHandler<void()>&) = 0;
    virtual bool interceptAuthenticationChallenge(ResourceLoader&, const AuthenticationChallenge&) = 0;
    virtual void loaderDidFinish(ResourceLoader&) = 0;
    virtual void loaderDidFail(ResourceLoader&, const ResourceError&) = 0;

    // Whether the Set-Cookie fields of the handle's responses wait for their onHeadersReceived verdict, which
    // stores or discards them.
    virtual bool holdsReceivedCookies(const ResourceHandle&) = 0;

    // The steps of a load that is not a ResourceLoader's: a ping, beacon or report.
    class Load : public RefCounted<Load> {
    public:
        virtual ~Load() = default;
        // The request to send, or a null request and the error the load fails with. A redirect's request
        // comes with its redirect response.
        virtual void willSendRequest(ResourceRequest&&, ResourceResponse&& redirectResponse, CompletionHandler<void(ResourceRequest&&, ResourceError&&)>&&) = 0;
        virtual void didCreateHandle(ResourceHandle&) = 0;
        // A redirect response the load does not follow, and the error the load fails with.
        virtual void didReceiveRedirectResponse(ResourceResponse&&, CompletionHandler<void(ResourceError&&)>&&) = 0;
        // The response the load completes with, and the error it fails with; or a request the load continues
        // with in place of the response.
        virtual void didReceiveResponse(ResourceResponse&&, CompletionHandler<void(ResourceResponse&&, ResourceRequest&&, ResourceError&&)>&&) = 0;
        virtual void didComplete(const ResourceError&, const ResourceResponse&) = 0;
    };
    virtual RefPtr<Load> pingLoad(LocalFrame&, const ResourceRequest&, const FetchOptions&) = 0;

    // A synchronous load, which no verdict can hold: the thread that runs the extensions' listeners waits on it.
    class SynchronousLoad : public RefCounted<SynchronousLoad> {
    public:
        virtual ~SynchronousLoad() = default;
        virtual void didComplete(const ResourceResponse&, const ResourceError&) = 0;
    };
    virtual RefPtr<SynchronousLoad> willLoadSynchronously(FrameLoader&, const ResourceRequest&, const FetchOptions&) = 0;

    // A WebSocket's handshake, which opens its connection once the handler is called with true.
    virtual bool interceptWebSocket(Document&, const URL&, CompletionHandler<void(bool)>&&) = 0;

protected:
    // The loader's own steps, which a held load resumes with.
    static void continueRedirection(ResourceLoader&, ResourceRequest&&, const ResourceResponse& redirectResponse, CompletionHandler<void(ResourceRequest&&)>&&);
    static void continueAuthenticationChallenge(ResourceLoader&, const AuthenticationChallenge&);
    // Ends the loader's network load without telling the loader.
    static void stopNetworkLoad(ResourceLoader&);
};

} // namespace WebCore
