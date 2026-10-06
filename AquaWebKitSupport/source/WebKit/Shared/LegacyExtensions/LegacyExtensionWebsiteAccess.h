// The website access a Safari 7 extension's Info.plist grants it (Permissions > Website Access), which Safari
// applies to its content scripts and the bridge applies to its cookies and webRequest events.

#pragma once

#include <wtf/JSONValues.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit::LegacyExtensions {

struct WebsiteAccess {
    enum class Level : uint8_t { None, Some, All };

    Level level { Level::None };
    // Allowed Domains: a host, or "*.host" for the host and its subdomains.
    Vector<String> domains;
    bool includesSecurePages { false };

    // Whether a web URL is within the access: https and wss only with Include Secure Pages.
    bool allows(const URL&) const;

    Ref<JSON::Object> toJSON() const;
    static WebsiteAccess fromJSON(const JSON::Object&);
};

} // namespace WebKit::LegacyExtensions
