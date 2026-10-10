#include "config.h"
#include "LegacyLoadInterceptor.h"

#include "ResourceHandle.h"
#include "ResourceLoader.h"

namespace WebCore {

static LegacyLoadInterceptor* interceptor;

LegacyLoadInterceptor* LegacyLoadInterceptor::singleton()
{
    return interceptor;
}

void LegacyLoadInterceptor::setSingleton(LegacyLoadInterceptor* newInterceptor)
{
    interceptor = newInterceptor;
}

LegacyLoadInterceptor::~LegacyLoadInterceptor() = default;

void LegacyLoadInterceptor::continueRedirection(ResourceLoader& loader, ResourceRequest&& request, const ResourceResponse& redirectResponse, CompletionHandler<void(ResourceRequest&&)>&& completionHandler)
{
    loader.willSendRequestInternal(WTF::move(request), redirectResponse, WTF::move(completionHandler));
}

void LegacyLoadInterceptor::continueAuthenticationChallenge(ResourceLoader& loader, const AuthenticationChallenge& challenge)
{
    RefPtr handle = loader.m_handle;
    loader.didReceiveAuthenticationChallenge(handle.get(), challenge);
}

void LegacyLoadInterceptor::stopNetworkLoad(ResourceLoader& loader)
{
    if (RefPtr handle = std::exchange(loader.m_handle, nullptr)) {
        handle->clearClient();
        handle->cancel();
    }
}

} // namespace WebCore
