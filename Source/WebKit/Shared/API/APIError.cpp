/*
 * Copyright (C) 2010-2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "APIError.h"

#include <wtf/NeverDestroyed.h>
#include <wtf/text/WTFString.h>

namespace API {

const WTF::String& Error::webKitErrorDomain()
{
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitErrorDomain"));
    return webKitErrorDomainString;
}

const WTF::String& Error::webKitNetworkErrorDomain()
{
// MAVERICKS_BACKPORT: this port enables USE(GLIB) for GStreamer only; the API consumer is Cocoa
// Safari, not the GTK/WPE API. Keep the Cocoa unified "WebKitErrorDomain" for the network/policy/
// plugin domains: Safari 7 suppresses the error page for a provisional load that becomes a download
// only when the error is (WebKitErrorDomain, kWKErrorCodeFrameLoadInterruptedByPolicyChange) —
// the GLib split-domain strings ("WebKitPolicyError" etc.) defeat that check and every download
// (PDF, blob:, attachments) paints a "Safari can't open the page" error page.
    // MAVERICKS_BACKPORT: exclude Cocoa (this port enables USE(GLIB) only for GStreamer) so the network domain stays the unified webKitErrorDomain(); the GLib "WebKitNetworkError" string defeats Safari 7's download error-page suppression.
#if USE(GLIB) && !PLATFORM(COCOA)
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitNetworkError"));
    return webKitErrorDomainString;
#else
    return webKitErrorDomain();
#endif
}

const WTF::String& Error::webKitPolicyErrorDomain()
{
    // MAVERICKS_BACKPORT: exclude Cocoa (this port enables USE(GLIB) only for GStreamer) so the policy domain stays the unified webKitErrorDomain(); the GLib "WebKitPolicyError" string defeats Safari 7's download error-page suppression.
#if USE(GLIB) && !PLATFORM(COCOA)
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitPolicyError"));
    return webKitErrorDomainString;
#else
    return webKitErrorDomain();
#endif
}

const WTF::String& Error::webKitPluginErrorDomain()
{
    // MAVERICKS_BACKPORT: exclude Cocoa (this port enables USE(GLIB) only for GStreamer) so the plugin domain stays the unified webKitErrorDomain(); the GLib "WebKitPluginError"/"WebKitMediaError" string defeats Safari 7's download error-page suppression.
#if USE(GLIB) && !PLATFORM(COCOA)
#if ENABLE(2022_GLIB_API)
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitMediaError"));
#else
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitPluginError"));
#endif
    return webKitErrorDomainString;
#else
    return webKitErrorDomain();
#endif
}

#if USE(SOUP)
const WTF::String& Error::webKitDownloadErrorDomain()
{
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitDownloadError"));
    return webKitErrorDomainString;
}
#endif

#if PLATFORM(GTK)
const WTF::String& Error::webKitPrintErrorDomain()
{
    static NeverDestroyed<WTF::String> webKitErrorDomainString(MAKE_STATIC_STRING_IMPL("WebKitPrintError"));
    return webKitErrorDomainString;
}
#endif

} // namespace WebKit
