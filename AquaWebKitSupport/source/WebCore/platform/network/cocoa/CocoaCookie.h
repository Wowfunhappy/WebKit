// native cookie storage integrity shared by HTTP and DOM writes.
#pragma once

#include "Cookie.h"
#include "SameSiteInfo.h"
#include <wtf/RetainPtr.h>
#include <wtf/URL.h>

OBJC_CLASS NSHTTPCookie;
OBJC_CLASS NSHTTPCookieStorage;

namespace WebCore {
// One HTTP field produces at most one structured cookie before native storage. A Partitioned
// attribute is keyed by the request's top-level site.
WEBCORE_EXPORT std::optional<Cookie> parseHTTPSetCookie(const String&, const URL&, const String& partition = { });
WEBCORE_EXPORT String cookiePartitionForTopLevelURL(const URL&);
// The same-site context of the Cookie field a request carries: a cross-site top-level navigation
// takes Lax cookies only with a safe method, which CFNetwork reads off the request it sends.
WEBCORE_EXPORT SameSiteInfo cookieRequestSameSiteInfo(const ResourceRequest&);
}
