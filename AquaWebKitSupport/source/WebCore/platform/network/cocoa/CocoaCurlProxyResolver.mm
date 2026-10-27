/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlProxyResolver.h"
#include <CFNetwork/CFNetwork.h>
#include <wtf/RunLoop.h>
#include <wtf/text/MakeString.h>

namespace WebCore {
Ref<CocoaCurlProxyResolver> CocoaCurlProxyResolver::createForRoutes(const URL& url, CFDictionaryRef settings, RoutesCompletion&& completion)
{
    return adoptRef(*new CocoaCurlProxyResolver(url, settings, WTF::move(completion)));
}

Ref<CocoaCurlProxyResolver> CocoaCurlProxyResolver::createForAutoConfiguration(const URL& url, CFDictionaryRef proxy, RoutesCompletion&& completion)
{
    Ref resolver = createForRoutes(url, nullptr, WTF::move(completion));
    resolver->m_autoConfiguration = proxy;
    return resolver;
}

CocoaCurlProxyResolver::CocoaCurlProxyResolver(const URL& url, CFDictionaryRef settings, RoutesCompletion&& completion)
    : m_runLoop(RunLoop::currentSingleton())
    , m_url(url)
    , m_settings(settings)
    , m_completion(WTF::move(completion))
{
}

CocoaCurlProxyResolver::~CocoaCurlProxyResolver()
{
    cancel();
}

void CocoaCurlProxyResolver::start()
{
    ASSERT(m_runLoop->isCurrent());
    if (m_autoConfiguration) {
        const void* proxy = m_autoConfiguration.get();
        auto proxies = adoptCF(CFArrayCreate(kCFAllocatorDefault, &proxy, 1, &kCFTypeArrayCallBacks));
        resolved(proxies.get(), nullptr);
        return;
    }
    if (!m_settings || !CFDictionaryGetCount(m_settings.get()))
        m_settings = adoptCF(CFNetworkCopySystemProxySettings());
    if (!m_settings) {
        finish(nullptr, "System proxy settings are unavailable"_s);
        return;
    }
    auto url = m_url.createCFURL();
    auto proxies = adoptCF(CFNetworkCopyProxiesForURL(url.get(), m_settings.get()));
    resolved(proxies.get(), nullptr);
}

void CocoaCurlProxyResolver::cancel()
{
    if (m_pacSource)
        CFRunLoopSourceInvalidate(m_pacSource.get());
    m_pacSource = nullptr;
    m_completion = nullptr;
}

void CocoaCurlProxyResolver::finish(CFArrayRef proxies, const String& error)
{
    Ref protectedThis { *this };
    auto completion = WTF::move(m_completion);
    cancel();
    if (completion)
        completion(retainPtr(proxies), error);
}

void CocoaCurlProxyResolver::resolved(CFArrayRef proxies, CFErrorRef error)
{
    Ref protectedThis { *this };
    if (m_pacSource)
        CFRunLoopSourceInvalidate(m_pacSource.get());
    m_pacSource = nullptr;
    if (!m_completion)
        return;
    if (error || !proxies || !CFArrayGetCount(proxies)) {
        String message = error ? String(adoptCF(CFErrorCopyDescription(error)).get()) : "System proxy resolution returned no route"_s;
        finish(nullptr, message);
        return;
    }
    RetainPtr proxy = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(proxies, 0));
    auto type = static_cast<CFStringRef>(CFDictionaryGetValue(proxy.get(), kCFProxyTypeKey));
    if (type && (CFEqual(type, kCFProxyTypeAutoConfigurationURL) || CFEqual(type, kCFProxyTypeAutoConfigurationJavaScript))) {
        auto callback = [](void* context, CFArrayRef result, CFErrorRef failure) {
            static_cast<CocoaCurlProxyResolver*>(context)->resolved(result, failure);
        };
        CFStreamClientContext context { 0, this,
            [](void* pointer) -> void* { static_cast<CocoaCurlProxyResolver*>(pointer)->ref(); return pointer; },
            [](void* pointer) { static_cast<CocoaCurlProxyResolver*>(pointer)->deref(); }, nullptr };
        auto url = m_url.createCFURL();
        if (CFEqual(type, kCFProxyTypeAutoConfigurationURL)) {
            auto script = static_cast<CFURLRef>(CFDictionaryGetValue(proxy.get(), kCFProxyAutoConfigurationURLKey));
            if (script)
                m_pacSource = adoptCF(CFNetworkExecuteProxyAutoConfigurationURL(script, url.get(), callback, &context));
        } else {
            auto script = static_cast<CFStringRef>(CFDictionaryGetValue(proxy.get(), kCFProxyAutoConfigurationJavaScriptKey));
            if (script)
                m_pacSource = adoptCF(CFNetworkExecuteProxyAutoConfigurationScript(script, url.get(), callback, &context));
        }
        if (!m_pacSource) {
            finish(nullptr, "Could not execute proxy configuration"_s);
            return;
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), m_pacSource.get(), kCFRunLoopCommonModes);
        return;
    }
    finish(proxies, { });
}

} // namespace WebCore
