// See wk_samesite.h.
#include "wk_samesite.h"

#include "wk_hosts.h"
#include "wk_symbols.h"

#include <string.h>

// ---------------------------------------------------------------------------------------------------
// The encoded Comment.
//
//     wk16:<field count> <key>=<escaped UTF-16 code units> ...
//
// Keys have a fixed order, so one policy has one encoding and re-encoding a cookie leaves it equal to itself. The
// field count is what a comment of a server's own that happens to begin "wk16:" fails, so it is handed
// back as the comment it is rather than misread. Percent-encoding keeps the separators used by this
// private metadata format out of every encoded value, without changing the server's comment.
// ---------------------------------------------------------------------------------------------------

#define WK_BLOB_PREFIX "wk16:"
#define WK_BLOB_PREFIX_LENGTH 5

static const char kSameSiteEncoding[] = "CFNetwork SameSite cookie encoding";

static bool wk_isUnreserved(UniChar c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        || c == '.' || c == '_' || c == '~' || c == '-';
}

static bool wk_isHexDigit(UniChar c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static int wk_hexValue(UniChar c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return c - 'A' + 10;
}

// Walks |comment| and answers whether it is one of this layer's. When it is and |key| names a field it
// carries, *valueRange is that field's still-encoded value; otherwise *valueRange is empty at
// kCFNotFound. Allocation-free -- this runs once per cookie per request.
static bool wk_blobScan(CFStringRef comment, const char *key, CFRange *valueRange)
{
    valueRange->location = kCFNotFound;
    valueRange->length = 0;
    if (!comment)
        return false;

    CFIndex length = CFStringGetLength(comment);
    if (length < WK_BLOB_PREFIX_LENGTH + 1)
        return false;

    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(comment, &buffer, CFRangeMake(0, length));
#define WK_AT(index) CFStringGetCharacterFromInlineBuffer(&buffer, (index))

    for (CFIndex i = 0; i < WK_BLOB_PREFIX_LENGTH; ++i) {
        if (WK_AT(i) != (UniChar)WK_BLOB_PREFIX[i])
            return false;
    }

    CFIndex position = WK_BLOB_PREFIX_LENGTH;
    long count = 0, digits = 0;
    while (position < length) {
        UniChar c = WK_AT(position);
        if (c < '0' || c > '9')
            break;
        // A count larger than the characters left cannot be one of this layer's, and stopping here
        // keeps the arithmetic inside the type.
        if (count > length)
            return false;
        count = count * 10 + (c - '0');
        ++digits;
        ++position;
    }
    if (!digits || count < 1)
        return false;

    size_t keyLength = strlen(key);
    for (long field = 0; field < count; ++field) {
        if (position >= length || WK_AT(position) != ' ')
            return false;
        ++position;

        CFIndex keyStart = position;
        while (position < length) {
            UniChar c = WK_AT(position);
            if (c < 'a' || c > 'z')
                break;
            ++position;
        }
        CFIndex thisKeyLength = position - keyStart;
        if (!thisKeyLength)
            return false;
        if (position >= length || WK_AT(position) != '=')
            return false;
        ++position;

        CFIndex valueStart = position;
        while (position < length) {
            UniChar c = WK_AT(position);
            if (c == ' ')
                break;
            if (c == '%') {
                if (position + 4 >= length)
                    return false;
                for (CFIndex digit = 1; digit <= 4; ++digit) {
                    if (!wk_isHexDigit(WK_AT(position + digit)))
                        return false;
                }
                position += 5;
                continue;
            }
            if (!wk_isUnreserved(c))
                return false;
            ++position;
        }
        CFIndex valueLength = position - valueStart;
        if (valueRange->location == kCFNotFound && thisKeyLength == (CFIndex)keyLength) {
            bool matches = true;
            for (CFIndex i = 0; i < thisKeyLength && matches; ++i)
                matches = WK_AT(keyStart + i) == (UniChar)key[i];
            if (matches)
                *valueRange = CFRangeMake(valueStart, valueLength);
        }
    }
    if (position != length) {
        valueRange->location = kCFNotFound;
        valueRange->length = 0;
        return false;
    }
    return true;
#undef WK_AT
}

// Every NSString code unit has an encoding, including an unpaired surrogate in an application comment.
static CFStringRef wk_copyDecodedField(CFStringRef comment, CFRange range)
{
    CFMutableStringRef decoded = CFStringCreateMutable(NULL, 0);
    if (!decoded)
        return NULL;
    CFIndex end = range.location + range.length;
    for (CFIndex i = range.location; i < end; ++i) {
        UniChar c = CFStringGetCharacterAtIndex(comment, i);
        if (c == '%') {
            c = 0;
            for (unsigned digit = 0; digit < 4; ++digit)
                c = (UniChar)((c << 4) | wk_hexValue(CFStringGetCharacterAtIndex(comment, ++i)));
        }
        CFStringAppendCharacters(decoded, &c, 1);
    }
    return decoded;
}

static CFStringRef wk_copyPercentEncoded(CFStringRef value)
{
    CFMutableStringRef encoded = CFStringCreateMutable(NULL, 0);
    if (!encoded)
        return NULL;
    static const char hex[] = "0123456789ABCDEF";
    for (CFIndex i = 0, length = CFStringGetLength(value); i < length; ++i) {
        UniChar c = CFStringGetCharacterAtIndex(value, i);
        if (wk_isUnreserved(c))
            CFStringAppendCharacters(encoded, &c, 1);
        else {
            UniChar escaped[] = { '%', hex[(c >> 12) & 15], hex[(c >> 8) & 15], hex[(c >> 4) & 15], hex[c & 15] };
            CFStringAppendCharacters(encoded, escaped, 5);
        }
    }
    return encoded;
}

CFStringRef wk_cookieBlobCreate(CFStringRef sameSite, CFStringRef created, CFStringRef setInJavaScript, CFStringRef comment)
{
    if (!sameSite && !created && !setInJavaScript)
        return comment ? (CFStringRef)CFRetain(comment) : NULL;

    CFStringRef encodedSameSite = sameSite ? wk_copyPercentEncoded(sameSite) : NULL;
    CFStringRef encodedCreated = created ? wk_copyPercentEncoded(created) : NULL;
    CFStringRef encodedSetInJavaScript = setInJavaScript ? wk_copyPercentEncoded(setInJavaScript) : NULL;
    CFStringRef encodedComment = comment ? wk_copyPercentEncoded(comment) : NULL;
    CFMutableStringRef blob = NULL;
    if ((!sameSite || encodedSameSite) && (!created || encodedCreated) && (!setInJavaScript || encodedSetInJavaScript)
        && (!comment || encodedComment)) {
        int fields = (encodedComment ? 1 : 0) + (encodedCreated ? 1 : 0) + (encodedSameSite ? 1 : 0)
            + (encodedSetInJavaScript ? 1 : 0);
        blob = CFStringCreateMutable(NULL, 0);
        if (!blob)
            wk_patch_fail(kSameSiteEncoding, "a comment could not be allocated");
        CFStringAppendFormat(blob, NULL, CFSTR(WK_BLOB_PREFIX "%d"), fields);
        if (encodedComment)
            CFStringAppendFormat(blob, NULL, CFSTR(" c=%@"), encodedComment);
        if (encodedCreated)
            CFStringAppendFormat(blob, NULL, CFSTR(" cr=%@"), encodedCreated);
        if (encodedSameSite)
            CFStringAppendFormat(blob, NULL, CFSTR(" ss=%@"), encodedSameSite);
        if (encodedSetInJavaScript)
            CFStringAppendFormat(blob, NULL, CFSTR(" js=%@"), encodedSetInJavaScript);
    }
    if (encodedSameSite)
        CFRelease(encodedSameSite);
    if (encodedCreated)
        CFRelease(encodedCreated);
    if (encodedSetInJavaScript)
        CFRelease(encodedSetInJavaScript);
    if (encodedComment)
        CFRelease(encodedComment);

    return blob;
}

// The creation time the caller of +[NSHTTPCookie cookieWithProperties:] asked for, which 10.9's own
// record cannot carry (measured: any "Created" a caller passes comes back as 1).
CFStringRef wk_cookieBlobCopyCreated(CFStringRef comment)
{
    CFRange range;
    if (!wk_blobScan(comment, "cr", &range) || range.location == kCFNotFound)
        return NULL;
    return wk_copyDecodedField(comment, range);
}

// Whether a script wrote this cookie. 10.9's NSHTTPCookie drops the SetInJavaScript property the moment
// it is handed one (measured: the key is absent from -properties before the cookie is even stored), and
// the mark is what NetworkStorageSession::deleteCookiesForHostnames selects script-written cookies by.
CFStringRef wk_cookieBlobCopySetInJavaScript(CFStringRef comment)
{
    CFRange range;
    if (!wk_blobScan(comment, "js", &range) || range.location == kCFNotFound)
        return NULL;
    return wk_copyDecodedField(comment, range);
}

CFStringRef wk_sameSiteCopyValue(CFStringRef comment)
{
    CFRange range;
    if (!wk_blobScan(comment, "ss", &range) || range.location == kCFNotFound)
        return NULL;
    return wk_copyDecodedField(comment, range);
}

CFStringRef wk_sameSiteCopyServerComment(CFStringRef comment)
{
    if (!comment)
        return NULL;
    CFRange range;
    if (!wk_blobScan(comment, "c", &range))
        return (CFStringRef)CFRetain(comment);
    if (range.location == kCFNotFound)
        return NULL;
    return wk_copyDecodedField(comment, range);
}

// The policy |value| names. "None" is permissive; a value the modern constants do not name leaves the
// attribute with no meaning, and RFC 6265bis 5.4.7 hands such a cookie the default enforcement, which
// is Lax. A cookie carrying no SameSite attribute at all never reaches here -- its comment has no
// policy field and wk_sameSitePolicyOfComment answers None -- so this is only about a value that was
// written and is not one of the three.
wk_same_site_policy wk_sameSitePolicyOfValue(CFStringRef value)
{
    if (!value || CFStringCompare(value, CFSTR("none"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
        return WK_SAME_SITE_NONE;
    if (CFStringCompare(value, CFSTR("strict"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
        return WK_SAME_SITE_STRICT;
    return WK_SAME_SITE_LAX;
}

wk_same_site_policy wk_sameSitePolicyOfComment(CFStringRef comment)
{
    CFStringRef value = wk_sameSiteCopyValue(comment);
    wk_same_site_policy policy = wk_sameSitePolicyOfValue(value);
    if (value)
        CFRelease(value);
    return policy;
}

bool wk_sameSiteAllows(wk_same_site_policy policy, bool isSameSite, bool isTopLevelNavigation, bool isSafeMethod)
{
    if (policy == WK_SAME_SITE_NONE || isSameSite)
        return true;
    if (policy == WK_SAME_SITE_STRICT)
        return false;
    return isTopLevelNavigation && isSafeMethod;
}

// ---------------------------------------------------------------------------------------------------
// Same-site, re-derived at every hop.
//
// CFNetwork carries a request's cookie-policy properties across an internal redirect verbatim while the
// URL changes host, so the stamp says what the first hop was, not what this one is. Only the comparison
// answers for this hop.
// ---------------------------------------------------------------------------------------------------

// The longest suffix of |host| and |otherHost| that begins at a label boundary in both, as a count of
// labels. Two hosts that share nothing answer 0, and a host and a subdomain of it answer the shorter
// one's label count.
bool wk_sameSiteURLsAreSameSite(CFURLRef siteForCookies, CFURLRef url)
{
    CFStringRef site = siteForCookies ? CFURLCopyHostName(siteForCookies) : NULL;
    CFStringRef host = url ? CFURLCopyHostName(url) : NULL;
    CFStringRef registrableDomain = wk_copyRegistrableDomain(site);
    bool sameSite = registrableDomain && wk_registrableDomainMatchesHost(registrableDomain, host);
    if (site)
        CFRelease(site);
    if (host)
        CFRelease(host);
    if (registrableDomain)
        CFRelease(registrableDomain);
    return sameSite;
}

// Native URL-scoped cookie reads obey path boundaries and send order.
bool wk_cookiePathMatchesRequestPath(CFStringRef cookiePath, CFStringRef requestPath)
{
    if (!cookiePath || !requestPath)
        return true;
    CFIndex cookieLength = CFStringGetLength(cookiePath);
    CFIndex requestLength = CFStringGetLength(requestPath);
    // No path names the root, which every request-path is under.
    if (!cookieLength)
        return true;
    if (cookieLength > requestLength)
        return false;
    if (CFStringCompare(cookiePath, requestPath, 0) == kCFCompareEqualTo)
        return true;
    if (CFStringGetCharacterAtIndex(cookiePath, cookieLength - 1) == '/')
        return true;
    return CFStringGetCharacterAtIndex(requestPath, cookieLength) == '/';
}

// The path a read is for, as a cookie-path is written: a URL with no path names the root.
CFStringRef wk_requestPathCreate(CFURLRef url)
{
    CFStringRef path = url ? CFURLCopyPath(url) : NULL;
    if (path && CFStringGetLength(path))
        return path;
    if (path)
        CFRelease(path);
    return (CFStringRef)CFRetain(CFSTR("/"));
}

// RFC 6265bis 5.5 sends the cookie with the longer path first. 10.9 answers host-only cookies ahead of
// the ones carrying a Domain attribute and orders by path length only within each of those groups, so
// a /cookies/attributes cookie with a Domain follows a /cookies one without. Answers whether |path|
// must precede |otherPath|; equal lengths answer false both ways, which leaves the caller's existing
// order among them -- 10.9 sorts those by name where the RFC wants creation order, and its creation
// time is whole seconds, so that much it cannot express.
bool wk_cookiePathSortsFirst(CFStringRef path, CFStringRef otherPath)
{
    CFIndex length = path ? CFStringGetLength(path) : 0;
    CFIndex otherLength = otherPath ? CFStringGetLength(otherPath) : 0;
    return length > otherLength;
}

// A CTL other than HTAB: %x00-08, %x0A-1F or %x7F.
