#include "config.h"
#include "LegacyExtensionWebsiteAccess.h"

#include <wtf/text/MakeString.h>

namespace WebKit::LegacyExtensions {

bool WebsiteAccess::allows(const URL& url) const
{
    if (!url.protocolIsInHTTPFamily() && !url.protocolIs("ws"_s) && !url.protocolIs("wss"_s))
        return false;
    if ((url.protocolIs("https"_s) || url.protocolIs("wss"_s)) && !includesSecurePages)
        return false;
    switch (level) {
    case Level::None:
        return false;
    case Level::All:
        return true;
    case Level::Some:
        break;
    }
    auto host = url.host().convertToASCIILowercase();
    return domains.containsIf([&](auto& domain) {
        if (!domain.startsWith("*."_s))
            return host == domain;
        auto base = StringView(domain).substring(2);
        return host == base || (host.length() > base.length() && host.endsWith(base) && host[host.length() - base.length() - 1] == '.');
    });
}

Vector<String> WebsiteAccess::urlPatterns() const
{
    Vector<String> hosts;
    switch (level) {
    case Level::None:
        return { };
    case Level::All:
        hosts.append("*"_s);
        break;
    case Level::Some:
        hosts = domains;
        break;
    }
    Vector<ASCIILiteral> schemes { "http"_s, "ws"_s };
    if (includesSecurePages)
        schemes.appendList({ "https"_s, "wss"_s });
    Vector<String> patterns;
    for (auto scheme : schemes) {
        for (auto& host : hosts)
            patterns.append(makeString(scheme, "://"_s, host, "/*"_s));
    }
    return patterns;
}

Ref<JSON::Object> WebsiteAccess::toJSON() const
{
    auto object = JSON::Object::create();
    object->setString("level"_s, level == Level::All ? "All"_s : level == Level::Some ? "Some"_s : "None"_s);
    auto domainsArray = JSON::Array::create();
    for (auto& domain : domains)
        domainsArray->pushString(domain);
    object->setArray("domains"_s, WTF::move(domainsArray));
    object->setBoolean("includesSecurePages"_s, includesSecurePages);
    return object;
}

WebsiteAccess WebsiteAccess::fromJSON(const JSON::Object& object)
{
    WebsiteAccess access;
    auto level = object.getString("level"_s);
    access.level = level == "All"_s ? Level::All : level == "Some"_s ? Level::Some : Level::None;
    if (RefPtr domains = object.getArray("domains"_s)) {
        for (auto& value : *domains) {
            if (auto domain = value->asString(); !domain.isNull())
                access.domains.append(domain.convertToASCIILowercase());
        }
    }
    access.includesSecurePages = object.getBoolean("includesSecurePages"_s).value_or(false);
    return access;
}

} // namespace WebKit::LegacyExtensions
