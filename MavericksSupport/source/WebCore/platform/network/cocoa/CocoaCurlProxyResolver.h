/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// Cocoa curl routes use the system proxy resolver, including PAC and bypass rules.
#include <CoreFoundation/CoreFoundation.h>
#include <curl/curl.h>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCounted.h>
#include <wtf/RetainPtr.h>
#include <wtf/URL.h>
#include <wtf/RunLoop.h>

namespace WebCore {
class WEBCORE_EXPORT CocoaCurlProxyResolver final : public RefCounted<CocoaCurlProxyResolver> {
public:
    using Completion = CompletionHandler<void(RetainPtr<CFDictionaryRef>&&, const String& error)>;
    static Ref<CocoaCurlProxyResolver> create(const URL&, CFDictionaryRef configuredSettings, Completion&&);
    ~CocoaCurlProxyResolver();
    void start();
    void cancel();
    static bool applyCredentials(CURL*, CFDictionaryRef, long authentication, const String& user, const String& password);
    static bool apply(CURL*, CFDictionaryRef, String& host, int& port);
private:
    CocoaCurlProxyResolver(const URL&, CFDictionaryRef, Completion&&);
    void resolved(CFArrayRef, CFErrorRef);
    void finish(CFDictionaryRef, const String&);
    Ref<RunLoop> m_runLoop;
    URL m_url;
    RetainPtr<CFDictionaryRef> m_settings;
    RetainPtr<CFRunLoopSourceRef> m_pacSource;
    Completion m_completion;
};
} // namespace WebCore
