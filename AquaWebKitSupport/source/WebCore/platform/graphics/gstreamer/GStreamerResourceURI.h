#pragma once

#include "GStreamerCommon.h"
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

inline URL gStreamerPlaybinURL(const URL& url)
{
    if (isProtocolAllowed(url))
        return url;
    return URL { makeString("webkit-resource:"_s, url.string()) };
}

inline URL webCoreURLFromGStreamerURI(String&& uri)
{
    constexpr auto prefix = "webkit-resource:"_s;
    if (uri.startsWith(prefix))
        return URL { uri.substring(prefix.length()) };
    return URL { WTF::move(uri) };
}

} // namespace WebCore
