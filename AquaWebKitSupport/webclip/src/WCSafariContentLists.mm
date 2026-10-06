// What Safari 7 does with an extension's content lists and files that WebCore decides: the URL patterns a
// content script or style sheet may apply to, and the MIME type of a file it serves.

#include "cmakeconfig.h"

#include <wtf/Platform.h>
#include <JavaScriptCore/JSExportMacros.h>
#include <WebCore/PlatformExportMacros.h>
#include <pal/ExportMacros.h>

#include <WebCore/MIMETypeRegistry.h>
#include <WebCore/UserContentURLPattern.h>
#include <wtf/Vector.h>
#include <wtf/cocoa/VectorCocoa.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#import "WCSafariContentLists.h"

namespace {

enum class Level { None, Some, All };

struct WebsiteAccess {
    Level level { Level::None };
    // Allowed Domains: a host, or "*.host" for the host and its subdomains.
    Vector<String> domains;
    bool includesSecurePages { false };
};

}

static WebsiteAccess websiteAccess(NSDictionary *permissions)
{
    WebsiteAccess access;
    NSDictionary *websiteAccess = [permissions isKindOfClass:NSDictionary.class] ? permissions[@"Website Access"] : nil;
    if (![websiteAccess isKindOfClass:NSDictionary.class])
        return access;
    NSString *level = websiteAccess[@"Level"];
    if ([level isEqual:@"All"])
        access.level = Level::All;
    else if ([level isEqual:@"Some"])
        access.level = Level::Some;
    NSArray *domains = websiteAccess[@"Allowed Domains"];
    for (id domain in [domains isKindOfClass:NSArray.class] ? domains : @[ ]) {
        if ([domain isKindOfClass:NSString.class])
            access.domains.append(String(domain).convertToASCIILowercase());
    }
    NSNumber *includesSecurePages = websiteAccess[@"Include Secure Pages"];
    access.includesSecurePages = [includesSecurePages isKindOfClass:NSNumber.class] && includesSecurePages.boolValue;
    return access;
}

static bool extensionDomainMatchesHost(const String& domain, const String& host)
{
    if (!domain.startsWith("*."_s))
        return equalIgnoringASCIICase(domain, host);
    auto base = StringView(domain).substring(2);
    return equalIgnoringASCIICase(base, host) || (host.length() > base.length() && host.endsWithIgnoringASCIICase(base) && host[host.length() - base.length() - 1] == '.');
}

// Safari's sanitizeExtensionContentWhitelistAndBlacklist: a content list is limited to the extension's
// website access, and never reaches the extension gallery, Reader, extensions' own pages or local files.
static void sanitizeContentLists(Vector<String>& whitelist, Vector<String>& blacklist, const WebsiteAccess& access)
{
    static constexpr auto httpPattern = "http://*/*"_s;
    static constexpr auto httpsPattern = "https://*/*"_s;
    static constexpr auto readerPattern = "safari-reader://*/*"_s;
    static constexpr auto extensionPattern = "safari-extension://*/*"_s;
    static constexpr auto filePattern = "file:///*"_s;
    if (access.level == Level::None || (access.level == Level::Some && access.domains.isEmpty())) {
        whitelist = { };
        blacklist = { extensionPattern, filePattern, httpPattern, httpsPattern, readerPattern };
        return;
    }
    blacklist.appendList({ "https://extensions.apple.com/*"_s, httpPattern, readerPattern, extensionPattern, filePattern });
    if (!access.includesSecurePages)
        blacklist.append(httpsPattern);

    size_t originalCount = whitelist.size();
    bool keptWebPattern = false;
    bool keptReaderPattern = false;
    for (size_t index = whitelist.size(); index--;) {
        WebCore::UserContentURLPattern pattern { whitelist[index] };
        bool isHTTP = pattern.isValid() && equalLettersIgnoringASCIICase(pattern.scheme(), "http"_s);
        bool isHTTPS = pattern.isValid() && equalLettersIgnoringASCIICase(pattern.scheme(), "https"_s);
        bool isReader = pattern.isValid() && equalLettersIgnoringASCIICase(pattern.scheme(), "safari-reader"_s);
        bool keep = isHTTP || isReader || (isHTTPS && access.includesSecurePages);
        if (keep && access.level == Level::Some) {
            keep = access.domains.containsIf([&](auto& domain) {
                return extensionDomainMatchesHost(domain, pattern.host()) && (domain.startsWith("*."_s) || !pattern.matchSubdomains());
            });
        }
        if (!keep) {
            whitelist.removeAt(index);
            continue;
        }
        if (isReader)
            keptReaderPattern = true;
        else
            keptWebPattern = true;
    }
    if (keptWebPattern)
        blacklist.removeFirst(httpPattern);
    if (keptReaderPattern)
        blacklist.removeFirst(readerPattern);
    else if (!keptWebPattern)
        blacklist.removeFirst(httpPattern);

    if (access.level == Level::All || !whitelist.isEmpty())
        return;
    if (originalCount) {
        whitelist = { };
        blacklist = { extensionPattern, filePattern, httpPattern, httpsPattern, readerPattern };
        return;
    }
    for (auto& domain : access.domains) {
        bool includesSubdomains = domain.startsWith("*."_s);
        auto host = includesSubdomains ? domain.substring(2) : domain;
        whitelist.append(makeString(includesSubdomains ? "http://*."_s : "http://"_s, host, "/*"_s));
        if (access.includesSecurePages)
            whitelist.append(makeString(includesSubdomains ? "https://*."_s : "https://"_s, host, "/*"_s));
    }
}

static Vector<String> strings(NSArray *array)
{
    Vector<String> result;
    for (id item in [array isKindOfClass:NSArray.class] ? array : @[ ]) {
        if ([item isKindOfClass:NSString.class])
            result.append(item);
    }
    return result;
}

void WCSanitizeContentLists(NSArray *whitelist, NSArray *blacklist, NSDictionary *permissions, NSArray **sanitizedWhitelist, NSArray **sanitizedBlacklist)
{
    auto allow = strings(whitelist);
    auto block = strings(blacklist);
    sanitizeContentLists(allow, block, websiteAccess(permissions));
    *sanitizedWhitelist = createNSArray(allow).autorelease();
    *sanitizedBlacklist = createNSArray(block).autorelease();
}

NSString *WCMIMETypeForPath(NSString *path)
{
    return WebCore::MIMETypeRegistry::mimeTypeForPath(String(path)).createNSString().autorelease();
}
