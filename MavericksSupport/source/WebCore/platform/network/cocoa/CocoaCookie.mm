// Cocoa cookie acceptance layers over the shared curl Set-Cookie grammar.
#import "config.h"
#import "CocoaCookie.h"
#import "Cookie.h"
#import "platform/network/curl/CookieUtil.h"
#import "PublicSuffixStore.h"
#import <algorithm>
#import <cmath>
#import <limits>
#import <wtf/ASCIICType.h>
#import <wtf/DateMath.h>
#import <wtf/WallTime.h>
#import <wtf/text/StringToIntegerConversion.h>
#import <wtf/text/MakeString.h>

namespace WebCore {

// RFC 6265 5.2: the name-value pair is everything before the first ';', and the attributes are read
// from what follows it.
// A field carrying no SameSite attribute leaves the cookie unrestricted, which is what
// Cookie::SameSitePolicy::None means and what an NSHTTPCookie with no SameSite property carries;
// sameSiteExplicitlyNone tells that apart from the attribute written out as "None", which the caller
// admits only from a secure origin.
static std::optional<Cookie> parseSetCookieField(const String& field, bool& sameSiteExplicitlyNone)
{
    if (field.length() >= 5000)
        return std::nullopt;
    auto separator = field.find(';');
    auto pair = separator == notFound ? field : field.left(separator);
    auto assignment = pair.find('=');
    Cookie cookie;
    // A field with no '=' is a value with an empty name, which the native jar stores like any other.
    cookie.name = (assignment == notFound ? emptyString() : pair.left(assignment)).trim(deprecatedIsSpaceOrNewline);
    cookie.value = (assignment == notFound ? pair : pair.substring(assignment + 1)).trim(deprecatedIsSpaceOrNewline);
    cookie.session = true;
    if (separator == notFound)
        return cookie;
    bool hasMaxAge = false;
    for (auto attribute : field.substring(separator + 1).splitAllowingEmptyEntries(';')) {
        auto assignmentPosition = attribute.find('=');
        auto name = (assignmentPosition == notFound ? attribute : attribute.left(assignmentPosition)).trim(deprecatedIsSpaceOrNewline);
        auto value = assignmentPosition == notFound ? emptyString() : attribute.substring(assignmentPosition + 1).trim(deprecatedIsSpaceOrNewline);
        if (equalLettersIgnoringASCIICase(name, "httponly"_s))
            cookie.httpOnly = true;
        else if (equalLettersIgnoringASCIICase(name, "secure"_s))
            cookie.secure = true;
        else if (equalLettersIgnoringASCIICase(name, "domain"_s)) {
            if (value.isEmpty())
                continue;
            if (!CookieUtil::isIPAddress(value) && !value.startsWith('.') && value.find('.') != notFound)
                value = makeString('.', value);
            cookie.domain = value.convertToASCIILowercase();
        } else if (equalLettersIgnoringASCIICase(name, "max-age"_s)) {
            // delta-seconds is 1*DIGIT after an optional '-'. A value the clock cannot represent
            // saturates at the range it can, where ignoring it would leave a persistent cookie a
            // session cookie.
            auto digits = StringView(value);
            bool negative = digits.startsWith('-');
            if (negative)
                digits = digits.substring(1);
            bool isDeltaSeconds = !digits.isEmpty();
            for (unsigned index = 0; isDeltaSeconds && index < digits.length(); ++index)
                isDeltaSeconds = isASCIIDigit(digits[index]);
            if (isDeltaSeconds) {
                auto seconds = parseInteger<int64_t>(value);
                double delta = seconds ? *seconds : (negative ? -std::numeric_limits<double>::infinity() : std::numeric_limits<double>::infinity());
                auto milliseconds = (WallTime::now().secondsSinceEpoch().value() + delta) * 1000;
                cookie.expires = std::clamp(milliseconds, -std::numeric_limits<double>::max(), std::numeric_limits<double>::max());
                cookie.session = false;
                hasMaxAge = true;
            } else {
                cookie.session = true;
                cookie.expires = std::nullopt;
            }
        } else if (equalLettersIgnoringASCIICase(name, "expires"_s) && !hasMaxAge) {
            double expires = parseDate(byteCast<Latin1Character>(value.utf8().span()));
            if (!std::isnan(expires)) {
                cookie.expires = expires;
                cookie.session = false;
            } else {
                cookie.session = true;
                cookie.expires = std::nullopt;
            }
        } else if (equalLettersIgnoringASCIICase(name, "path"_s))
            cookie.path = !value.isEmpty() && value.startsWith('/') ? value : emptyString();
        else if (equalLettersIgnoringASCIICase(name, "samesite"_s) && assignmentPosition != notFound) {
            sameSiteExplicitlyNone = equalLettersIgnoringASCIICase(value, "none"_s);
            cookie.sameSite = equalLettersIgnoringASCIICase(value, "strict"_s) ? Cookie::SameSitePolicy::Strict
                : sameSiteExplicitlyNone ? Cookie::SameSitePolicy::None : Cookie::SameSitePolicy::Lax;
        }
    }
    return cookie;
}

std::optional<Cookie> parseHTTPSetCookie(const String& field, const URL& url)
{
    for (auto character : StringView(field).codeUnits()) {
        if ((character < 0x20 && character != '\t') || character == 0x7f)
            return std::nullopt;
    }
    bool explicitNone = false;
    auto parsed = parseSetCookieField(field, explicitNone);
    if (!parsed)
        return std::nullopt;
    auto& cookie = *parsed;
    // RFC 6265bis section 5.6 limits the name/value pair to 4096 octets.
    if ((cookie.name.isEmpty() && cookie.value.isEmpty()) || cookie.name.utf8().length() + cookie.value.utf8().length() > 4096)
        return std::nullopt;
    auto host = url.host().toString().convertToASCIILowercase();
    bool hasDomain = !cookie.domain.isEmpty();
    if (hasDomain) {
        auto domain = cookie.domain.startsWith('.') ? cookie.domain.substring(1) : cookie.domain;
        if (domain.isEmpty() || domain.endsWith('.') || !domain.containsOnlyASCII())
            return std::nullopt;
        if (CookieUtil::isIPAddress(host) ? domain != host : !CookieUtil::domainMatch(makeString('.', domain), host))
            return std::nullopt;
        if (PublicSuffixStore::singleton().isPublicSuffix(domain)) {
            if (host != domain)
                return std::nullopt;
            hasDomain = false;
        }
        cookie.domain = hasDomain && !CookieUtil::isIPAddress(host) ? makeString('.', domain) : host;
    } else
        cookie.domain = host;
    cookie.created = WallTime::now().secondsSinceEpoch().milliseconds();
    bool hasRootPath = cookie.path == "/"_s;
    if (cookie.path.isEmpty())
        cookie.path = CookieUtil::defaultPathForURL(url);
    bool secureOrigin = url.protocolIs("https"_s) || url.protocolIs("wss"_s);
    if ((cookie.secure && !secureOrigin) || (explicitNone && !cookie.secure))
        return std::nullopt;
    if ((cookie.name.startsWithIgnoringASCIICase("__Secure-"_s) && !cookie.secure)
        || (cookie.name.startsWithIgnoringASCIICase("__Host-"_s) && (!cookie.secure || hasDomain || !hasRootPath))
        || (cookie.name.startsWithIgnoringASCIICase("__Http-"_s) && (!cookie.secure || !cookie.httpOnly))
        || (cookie.name.startsWithIgnoringASCIICase("__Host-Http-"_s) && (!cookie.secure || !cookie.httpOnly || hasDomain || !hasRootPath)))
        return std::nullopt;
    if (cookie.name.isEmpty() && (cookie.value.startsWithIgnoringASCIICase("__Secure-"_s) || cookie.value.startsWithIgnoringASCIICase("__Host-"_s)))
        return std::nullopt;
    // RFC 6265bis section 4.1.2.1 limits persistent cookies to 400 days.
    if (cookie.expires)
        cookie.expires = std::min(*cookie.expires, cookie.created + 400.0 * 24 * 60 * 60 * 1000);
    return parsed;
}

} // namespace WebCore

// the Objective-C WebSocket transport shares WebCore's per-field parser.
extern "C" WEBCORE_EXPORT CFTypeRef WebCoreCookieCreateFromHTTPResponseField(CFStringRef field, CFURLRef url)
{
    auto cookie = WebCore::parseHTTPSetCookie(String(field), URL(url));
    return cookie ? (CFTypeRef)cookie->createNSHTTPCookie().leakRef() : nullptr;
}

extern "C" WEBCORE_EXPORT void WebCoreCookieStorageSetHTTPResponseCookies(CFTypeRef storageValue, CFArrayRef cookies, CFURLRef responseURL, CFURLRef firstPartyURL, bool sameSite, bool topLevel)
{
    NSHTTPCookieStorage *storage = (NSHTTPCookieStorage *)storageValue;
    for (NSHTTPCookie *cookie in (NSArray *)cookies) {
        if (WebCore::Cookie(cookie).sameSite != WebCore::Cookie::SameSitePolicy::None && !sameSite && !topLevel)
            continue;
        [storage setCookies:@[cookie] forURL:(NSURL *)responseURL mainDocumentURL:(NSURL *)firstPartyURL];
    }
}
