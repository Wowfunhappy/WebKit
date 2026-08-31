// See wk_hosts.h.
#include "wk_hosts.h"

#include "wk_polyfill.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// The public-suffix oracle, exported on 10.9 but absent from the build SDK's stub library, and
// resolved through the layer because libpolyfill.a is force-loaded into images that do not link
// CFNetwork.
WK_SYSTEM_FN("CFNetwork", Boolean, _CFHostIsDomainTopLevel, (CFStringRef));

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
    bool isPublicSuffix = decoded && WK_SYSTEM(_CFHostIsDomainTopLevel)
        && WK_SYSTEM(_CFHostIsDomainTopLevel)(decoded);
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
