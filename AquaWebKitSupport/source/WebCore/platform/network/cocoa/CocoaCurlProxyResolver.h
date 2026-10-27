/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// The routes the system proxy resolver answers with for a URL, including PAC and bypass rules, in CFNetwork's order
// (CocoaCurlRouteResolver turns them into a load's route).
#include <CoreFoundation/CoreFoundation.h>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCounted.h>
#include <wtf/RetainPtr.h>
#include <wtf/URL.h>
#include <wtf/RunLoop.h>

namespace WebCore {
class WEBCORE_EXPORT CocoaCurlProxyResolver final : public RefCounted<CocoaCurlProxyResolver> {
public:
    using RoutesCompletion = CompletionHandler<void(RetainPtr<CFArrayRef>&&, const String& error)>;
    static Ref<CocoaCurlProxyResolver> createForRoutes(const URL&, CFDictionaryRef configuredSettings, RoutesCompletion&&);
    // The routes a proxy auto-configuration entry (kCFProxyTypeAutoConfigurationURL or JavaScript) answers with.
    static Ref<CocoaCurlProxyResolver> createForAutoConfiguration(const URL&, CFDictionaryRef proxy, RoutesCompletion&&);
    ~CocoaCurlProxyResolver();
    void start();
    void cancel();
private:
    CocoaCurlProxyResolver(const URL&, CFDictionaryRef, RoutesCompletion&&);
    void resolved(CFArrayRef, CFErrorRef);
    void finish(CFArrayRef, const String&);
    Ref<RunLoop> m_runLoop;
    URL m_url;
    RetainPtr<CFDictionaryRef> m_settings;
    RetainPtr<CFDictionaryRef> m_autoConfiguration;
    RetainPtr<CFRunLoopSourceRef> m_pacSource;
    RoutesCompletion m_completion;
};
} // namespace WebCore
