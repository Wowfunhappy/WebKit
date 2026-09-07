/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlProxyResolver.h"
#include <CFNetwork/CFNetwork.h>
#include <wtf/RunLoop.h>
#include <wtf/text/MakeString.h>

// CFNetwork selects routes; curl owns the resulting HTTP connection.
namespace WebCore {
Ref<CocoaCurlProxyResolver> CocoaCurlProxyResolver::create(const URL& url, CFDictionaryRef settings, Completion&& completion)
{
    return adoptRef(*new CocoaCurlProxyResolver(url, settings, WTF::move(completion)));
}

CocoaCurlProxyResolver::CocoaCurlProxyResolver(const URL& url, CFDictionaryRef settings, Completion&& completion)
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

void CocoaCurlProxyResolver::finish(CFDictionaryRef proxy, const String& error)
{
    Ref protectedThis { *this };
    auto completion = WTF::move(m_completion);
    cancel();
    if (completion)
        completion(retainPtr(proxy), error);
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
    finish(proxy.get(), { });
}

bool CocoaCurlProxyResolver::apply(CURL* easy, CFDictionaryRef proxy, String& proxyHost, int& proxyPort)
{
    auto type = static_cast<CFStringRef>(CFDictionaryGetValue(proxy, kCFProxyTypeKey));
    if (!type)
        return false;
    if (CFEqual(type, kCFProxyTypeNone)) {
        proxyHost = emptyString();
        proxyPort = 0;
        return curl_easy_setopt(easy, CURLOPT_PROXY, "") == CURLE_OK && curl_easy_setopt(easy, CURLOPT_NOPROXY, "*") == CURLE_OK;
    }
    auto host = static_cast<CFStringRef>(CFDictionaryGetValue(proxy, kCFProxyHostNameKey));
    auto port = static_cast<CFNumberRef>(CFDictionaryGetValue(proxy, kCFProxyPortNumberKey));
    if (!host || CFGetTypeID(host) != CFStringGetTypeID() || !port || CFGetTypeID(port) != CFNumberGetTypeID() || !CFNumberGetValue(port, kCFNumberIntType, &proxyPort) || proxyPort <= 0 || proxyPort > 65535)
        return false;
    proxyHost = host;
    long curlType;
    String scheme;
    if (CFEqual(type, kCFProxyTypeHTTP) || CFEqual(type, kCFProxyTypeHTTPS)) {
        curlType = CURLPROXY_HTTP;
        scheme = "http://"_s;
    } else if (CFEqual(type, kCFProxyTypeSOCKS)) {
        curlType = CURLPROXY_SOCKS5_HOSTNAME;
        scheme = "socks5h://"_s;
    } else
        return false;
    auto proxyURL = makeString(scheme, proxyHost.contains(':') ? "["_s : ""_s, proxyHost, proxyHost.contains(':') ? "]"_s : ""_s);
    return curl_easy_setopt(easy, CURLOPT_PROXY, proxyURL.utf8().data()) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYPORT, static_cast<long>(proxyPort)) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYTYPE, curlType) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_NOPROXY, "") == CURLE_OK;
}

// The credential belongs to the resolved proxy, independently of the request origin.
bool CocoaCurlProxyResolver::applyCredentials(CURL* easy, CFDictionaryRef proxy, long authentication, const String& suppliedUser, const String& suppliedPassword)
{
    String user = suppliedUser;
    String password = suppliedPassword;
    if (!authentication) {
        auto nativeUser = CFDictionaryGetValue(proxy, kCFProxyUsernameKey);
        auto nativePassword = CFDictionaryGetValue(proxy, kCFProxyPasswordKey);
        if (nativeUser && CFGetTypeID(nativeUser) != CFStringGetTypeID())
            return false;
        if (nativePassword && CFGetTypeID(nativePassword) != CFStringGetTypeID())
            return false;
        if (nativeUser || nativePassword) {
            user = static_cast<CFStringRef>(nativeUser);
            password = static_cast<CFStringRef>(nativePassword);
            authentication = CURLAUTH_ANY;
        }
    }
    return curl_easy_setopt(easy, CURLOPT_PROXYAUTH, authentication) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYUSERNAME, user.utf8().data()) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYPASSWORD, password.utf8().data()) == CURLE_OK;
}

} // namespace WebCore
