// See wk_hosts.h.
#include "wk_hosts.h"

#include "wk_polyfill.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static bool wk_nameIsTopLevelDomain(CFStringRef domain);

// The public-suffix oracle every consumer asks -- WebCore's PublicSuffixStore, SecurityOrigin's
// document.domain relaxation, the Cookie Store API's domain check, CSP source lists, extension match
// patterns, and this file -- answering from a table of top-level domains that was current in 2013. A
// name delegated or reserved since reads as an ordinary label there, so two hosts under it read as one
// registrable domain: a page on evil.app could relax document.domain to "app", a cookie could name
// Domain=app, and a subdomain's request was stamped cross-site to its own site.
//
// The public-suffix list's default rule supplies what the table lacks: a name no rule matches is a
// suffix of one label. That answers a top-level domain delegated after 2013, and one reserved rather
// than delegated (RFC 6761's test, example and invalid, which every WPT host is under and which no
// registry list names). `localhost` is the exception a list-driven browser makes by name, and an
// address is not a name at all. Additive: every answer 10.9 gives, co.uk and the internationalised
// U-labels included, is still its own.
WK_POLYFILL_REPLACES("CFNetwork", Boolean, _CFHostIsDomainTopLevel, (CFStringRef domain))
{
    return wk_nameIsTopLevelDomain(domain);
}

// A name of one label, ignoring a leading or trailing dot.
static bool wk_nameIsOneLabel(CFStringRef domain)
{
    CFIndex length = domain ? CFStringGetLength(domain) : 0;
    CFIndex start = length && CFStringGetCharacterAtIndex(domain, 0) == '.' ? 1 : 0;
    CFIndex end = length && CFStringGetCharacterAtIndex(domain, length - 1) == '.' ? length - 1 : length;
    if (end <= start)
        return false;
    CFRange dot;
    return !CFStringFindWithOptions(domain, CFSTR("."), CFRangeMake(start, end - start), 0, &dot);
}

// The same answer for this library's own readers, which reach the body above only in an image the
// replacement was installed into.
static bool wk_nameIsTopLevelDomain(CFStringRef domain)
{
    if (WK_ORIGINAL(_CFHostIsDomainTopLevel)(domain))
        return true;
    return wk_nameIsOneLabel(domain) && !wk_hostIsIPAddress(domain)
        && CFStringCompare(domain, CFSTR("localhost"), kCFCompareCaseInsensitive) != kCFCompareEqualTo;
}

bool wk_hostIsIPAddress(CFStringRef host)
{
    CFIndex length = host ? CFStringGetLength(host) : 0;
    if (!length)
        return false;
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(host, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i < length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (c == ':')
            return true;
        if ((c < '0' || c > '9') && c != '.')
            return false;
    }
    return true;
}

CFStringRef wk_copyDecodedHostName(CFStringRef name)
{
    if (!name)
        return NULL;
    if (CFStringFind(name, CFSTR("xn--"), kCFCompareCaseInsensitive).location == kCFNotFound)
        return (CFStringRef)CFRetain(name);

    typedef int32_t (*WKIDNToUnicode)(const UniChar *, int32_t, UniChar *, int32_t, int32_t, void *, int32_t *);
    static WKIDNToUnicode idnToUnicode;
    static bool resolved;
    if (!resolved) {
        idnToUnicode = (WKIDNToUnicode)dlsym(RTLD_DEFAULT, "uidna_IDNToUnicode");
        resolved = true;
    }
    CFIndex length = CFStringGetLength(name);
    if (!idnToUnicode || length >= 256)
        return (CFStringRef)CFRetain(name);

    UniChar source[256], decoded[256];
    CFStringGetCharacters(name, CFRangeMake(0, length), source);
    int32_t status = 0;
    int32_t decodedLength = idnToUnicode(source, (int32_t)length, decoded,
        (int32_t)(sizeof(decoded) / sizeof(decoded[0])), 0, NULL, &status);
    if (status > 0 || decodedLength <= 0)
        return (CFStringRef)CFRetain(name);
    return CFStringCreateWithCharacters(NULL, decoded, decodedLength);
}

bool wk_domainIsPublicSuffix(CFStringRef domain)
{
    CFStringRef decoded = wk_copyDecodedHostName(domain);
    bool isPublicSuffix = decoded && wk_nameIsTopLevelDomain(decoded);
    if (decoded)
        CFRelease(decoded);
    return isPublicSuffix;
}

// PublicSuffixStore::topPrivatelyControlledDomain, and its Cocoa half: the shortest suffix of |host|
// that starts one label ahead of a public suffix.
static bool wk_stringIsASCII(CFStringRef string)
{
    CFIndex length = CFStringGetLength(string);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(string, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i < length; ++i) {
        if (CFStringGetCharacterFromInlineBuffer(&buffer, i) > 127)
            return false;
    }
    return true;
}

static CFStringRef wk_copyTopPrivatelyControlledDomain(CFStringRef host)
{
    if (!CFStringGetLength(host))
        return NULL;
    if (!wk_stringIsASCII(host))
        return (CFStringRef)CFRetain(host);

    CFMutableStringRef lowercase = CFStringCreateMutableCopy(NULL, 0, host);
    if (!lowercase)
        return NULL;
    CFStringLowercase(lowercase, NULL);
    CFIndex length = CFStringGetLength(lowercase);

    if (CFEqual(lowercase, CFSTR("localhost")) || wk_hostIsIPAddress(lowercase))
        return lowercase;

    CFStringRef result = NULL;
    for (CFIndex labelStart = 0; labelStart < length; ) {
        CFRange separator;
        if (!CFStringFindWithOptions(lowercase, CFSTR("."), CFRangeMake(labelStart, length - labelStart), 0, &separator))
            break;
        CFStringRef candidate = CFStringCreateWithSubstring(NULL, lowercase,
            CFRangeMake(separator.location + 1, length - separator.location - 1));
        bool isPublicSuffix = candidate && wk_domainIsPublicSuffix(candidate);
        if (candidate)
            CFRelease(candidate);
        if (isPublicSuffix) {
            result = CFStringCreateWithSubstring(NULL, lowercase, CFRangeMake(labelStart, length - labelStart));
            break;
        }
        labelStart = separator.location + 1;
    }
    CFRelease(lowercase);
    return result;
}

// Memo over the derivation above. The answer is a pure function of the host — the public-suffix set
// behind _CFHostIsDomainTopLevel is fixed for the process — and this runs once per request while a
// page load asks about the same few hosts hundreds of times in a row; each miss costs a label walk of
// substring allocations and public-suffix oracle calls.
enum { WK_DOMAIN_MEMO_SLOTS = 8 };
static struct { CFStringRef host; CFStringRef domain; } wk_domainMemo[WK_DOMAIN_MEMO_SLOTS];
static unsigned wk_domainMemoNext;
static pthread_mutex_t wk_domainMemoLock = PTHREAD_MUTEX_INITIALIZER;

CFStringRef wk_copyRegistrableDomain(CFStringRef host)
{
    if (!host || !CFStringGetLength(host))
        return (CFStringRef)CFRetain(CFSTR("nullOrigin"));

    pthread_mutex_lock(&wk_domainMemoLock);
    for (unsigned i = 0; i < WK_DOMAIN_MEMO_SLOTS; ++i) {
        if (wk_domainMemo[i].host && CFEqual(wk_domainMemo[i].host, host)) {
            CFStringRef domain = (CFStringRef)CFRetain(wk_domainMemo[i].domain);
            pthread_mutex_unlock(&wk_domainMemoLock);
            return domain;
        }
    }
    pthread_mutex_unlock(&wk_domainMemoLock);

    CFStringRef domain = wk_copyTopPrivatelyControlledDomain(host);
    if (!domain)
        domain = (CFStringRef)CFRetain(host);

    // The key is a copy, not a retain: a caller's mutable string must not change under CFEqual.
    CFStringRef key = CFStringCreateCopy(NULL, host);
    if (key) {
        pthread_mutex_lock(&wk_domainMemoLock);
        unsigned slot = wk_domainMemoNext++ % WK_DOMAIN_MEMO_SLOTS;
        if (wk_domainMemo[slot].host) {
            CFRelease(wk_domainMemo[slot].host);
            CFRelease(wk_domainMemo[slot].domain);
        }
        wk_domainMemo[slot].host = key;
        wk_domainMemo[slot].domain = (CFStringRef)CFRetain(domain);
        pthread_mutex_unlock(&wk_domainMemoLock);
    }
    return domain;
}

bool wk_registrableDomainMatchesHost(CFStringRef registrableDomain, CFStringRef host)
{
    CFIndex hostLength = host ? CFStringGetLength(host) : 0;
    CFIndex domainLength = CFStringGetLength(registrableDomain);
    if (!hostLength)
        return CFEqual(registrableDomain, CFSTR("nullOrigin"));
    if (hostLength < domainLength)
        return false;
    CFStringRef tail = CFStringCreateWithSubstring(NULL, host,
        CFRangeMake(hostLength - domainLength, domainLength));
    bool endsWith = tail && CFEqual(tail, registrableDomain);
    if (tail)
        CFRelease(tail);
    if (!endsWith)
        return false;
    if (hostLength == domainLength)
        return true;
    return CFStringGetCharacterAtIndex(host, hostLength - domainLength - 1) == '.';
}
