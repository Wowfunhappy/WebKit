/*
 * Copyright (C) 2014-2017 Apple Inc. All rights reserved.
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

#import "config.h"
#import "UserAgent.h"

#if PLATFORM(MAC)

#import <wtf/text/MakeString.h>

namespace WebCore {

// AQUAWEBKIT: an application name that names Safari ("Version/<version> Safari/<build>", as Safari 7
// passes) names the Safari release this WebKit ships in. The application's other tokens stay.
ASCIILiteral safariApplicationNameForUserAgent()
{
    return "Version/26.0 Safari/605.1.15"_s;
}

static String applicationNameWithCurrentSafariVersion(const String& applicationName)
{
    StringView name { applicationName };
    for (size_t versionStart = name.find("Version/"_s); versionStart != notFound; versionStart = name.find("Version/"_s, versionStart + 1)) {
        if (versionStart && name[versionStart - 1] != ' ')
            continue;
        size_t safariStart = name.find(' ', versionStart);
        if (safariStart == notFound || !name.substring(safariStart + 1).startsWith("Safari/"_s))
            continue;
        size_t safariEnd = name.find(' ', safariStart + 1);
        if (safariEnd == notFound)
            safariEnd = name.length();
        return makeString(name.left(versionStart), safariApplicationNameForUserAgent(), name.substring(safariEnd));
    }
    return applicationName;
}

String standardUserAgentWithApplicationName(const String& applicationName, const String&, UserAgentType)
{
    // String appNameSuffix = applicationName.isEmpty() ? emptyString() : makeString(' ', applicationName);
    String appNameSuffix = applicationName.isEmpty() ? emptyString() : makeString(' ', applicationNameWithCurrentSafariVersion(applicationName)); // AQUAWEBKIT: see safariApplicationNameForUserAgent.

    return makeString("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"_s, appNameSuffix);
}

} // namespace WebCore

#endif // PLATFORM(MAC)
