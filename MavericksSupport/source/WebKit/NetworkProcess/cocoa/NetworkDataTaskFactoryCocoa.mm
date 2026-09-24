/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "config.h"
#import "NetworkDataTaskFactoryCocoa.h"

#import "NetworkDataTaskCocoa.h"
#import "NetworkDataTaskCurlCocoa.h"
#import "NetworkLoadParameters.h"
#import <WebCore/SecurityOrigin.h>
#import <atomic>
#import <mutex>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>

namespace WebKit {
using namespace WebCore;

// Any image in the network process may define
//
//     extern "C" CFURLRef WKExternalURLRewrite(CFURLRef url);
//
// It runs on the network process's main thread as each load starts, and returns a new URL (which the
// caller releases) to request in place of url, or NULL to request url itself.
using ExternalURLRewriteFunction = CFURLRef (*)(CFURLRef);

static std::atomic<bool> imagesAddedSinceSearch;

static void imageAdded(const struct mach_header*, intptr_t)
{
    imagesAddedSinceSearch.store(true, std::memory_order_release);
}

static ExternalURLRewriteFunction externalURLRewriteFunction()
{
    ASSERT(RunLoop::isMain());
    static ExternalURLRewriteFunction function;
    if (function)
        return function;

    static std::once_flag once;
    // Registration reports every image already loaded.
    std::call_once(once, [] {
        _dyld_register_func_for_add_image(imageAdded);
    });
    if (!imagesAddedSinceSearch.exchange(false, std::memory_order_acq_rel))
        return nullptr;

    auto* symbol = dlsym(RTLD_DEFAULT, "WKExternalURLRewrite");
    Dl_info info;
    if (!symbol || !dladdr(symbol, &info) || !info.dli_fname)
        return nullptr;
    // The handle is never closed, so the function's image stays loaded.
    if (!dlopen(info.dli_fname, RTLD_NOLOAD))
        return nullptr;
    function = reinterpret_cast<ExternalURLRewriteFunction>(symbol);
    return function;
}

static std::optional<NetworkLoadParameters> parametersWithExternalURLRewrite(const NetworkLoadParameters& parameters)
{
    auto function = externalURLRewriteFunction();
    if (!function)
        return std::nullopt;

    auto url = parameters.request.url().createCFURL();
    if (!url)
        return std::nullopt;
    auto rewrittenCFURL = adoptCF(function(url.get()));
    if (!rewrittenCFURL)
        return std::nullopt;
    URL rewrittenURL { rewrittenCFURL.get() };
    if (rewrittenURL == parameters.request.url())
        return std::nullopt;

    auto rewrittenParameters = parameters;
    auto& request = rewrittenParameters.request;
    // A top-level navigation's first party is its own URL, and a cross-site change of URL makes a request
    // not same-site, as they are on a redirect.
    if (parameters.isMainFrameNavigation)
        request.setFirstPartyForCookies(rewrittenURL);
    if (!SecurityOrigin::create(rewrittenURL)->isSameSiteAs(SecurityOrigin::create(parameters.request.url())))
        request.setIsSameSite(false);
    request.setURL(WTF::move(rewrittenURL));
    return rewrittenParameters;
}

Ref<NetworkDataTask> createNetworkDataTaskCocoa(NetworkSession& session, NetworkDataTaskClient& client, const NetworkLoadParameters& requestedParameters)
{
    auto rewrittenParameters = parametersWithExternalURLRewrite(requestedParameters);
    const auto& parameters = rewrittenParameters ? *rewrittenParameters : requestedParameters;
    if (NetworkDataTaskCurlCocoa::canHandle(session, parameters))
        return NetworkDataTaskCurlCocoa::create(session, client, parameters);
    return NetworkDataTaskCocoa::create(session, client, parameters);
}

} // namespace WebKit
