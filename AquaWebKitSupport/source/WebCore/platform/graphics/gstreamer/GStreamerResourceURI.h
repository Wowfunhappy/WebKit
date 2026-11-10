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

// The resources a manifest names (variants, segments, initialization maps, keys): file: ones load
// through WebCore as well, so the document's loading rules decide each of them.
inline gchar* gStreamerChildResourceURI(const gchar* uri)
{
    URL url { String::fromUTF8(uri) };
    if (url.protocolIsFile())
        return g_strdup(makeString("webkit-resource:"_s, url.string()).utf8().data());
    return g_strdup(gStreamerPlaybinURL(url).string().utf8().data());
}

inline URL webCoreURLFromGStreamerURI(String&& uri)
{
    constexpr auto prefix = "webkit-resource:"_s;
    if (uri.startsWith(prefix))
        return URL { uri.substring(prefix.length()) };
    return URL { WTF::move(uri) };
}

} // namespace WebCore
