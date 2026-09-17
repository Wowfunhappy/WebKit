// See wk_hosts.h.
#include "wk_hosts.h"

#include "wk_polyfill.h"

#include <libpsl.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static bool wk_nameIsTopLevelDomain(CFStringRef domain);

// WebCore, native-cookie policy and WebSocket same-site checks share the same current
// PSL implementation as curl, including explicit multi-label and private suffixes.
WK_POLYFILL_REPLACES("CFNetwork", Boolean, _CFHostIsDomainTopLevel, (CFStringRef domain))
{
    return wk_nameIsTopLevelDomain(domain);
}

static bool wk_nameIsTopLevelDomain(CFStringRef domain)
{
    // CFNetwork permits a leading cookie-domain dot, but rejects a trailing root label.
    if (!domain || !CFStringGetLength(domain) || wk_hostIsIPAddress(domain)
        || CFStringHasSuffix(domain, CFSTR(".")))
        return false;
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(domain), kCFStringEncodingUTF8);
    if (capacity < 0)
        return false;
    char *text = malloc((size_t)capacity + 1);
    if (!text)
        abort();
    if (!CFStringGetCString(domain, text, capacity + 1, kCFStringEncodingUTF8)) {
        free(text);
        return false;
    }
    char *normalized = NULL;
    psl_error_t error = psl_str_to_utf8lower(text, "UTF-8", NULL, &normalized);
    free(text);
    if (error == PSL_ERR_NO_MEM)
        abort();
    if (error != PSL_SUCCESS)
        return false;
    // The PSL's implicit "*" rule makes an unlisted top-level label a public suffix. CFNetwork applies it
    // to an ASCII label and not to a Unicode one, and an A-label answers as its Unicode form does.
    const char *topLabel = strrchr(normalized, '.');
    topLabel = topLabel ? topLabel + 1 : normalized;
    bool starRuleApplies = strncmp(topLabel, "xn--", 4);
    for (const char *c = topLabel; *c && starRuleApplies; ++c)
        starRuleApplies = !(*c & 0x80);
    bool result = psl_is_public_suffix2(psl_builtin(), normalized,
        starRuleApplies ? PSL_TYPE_ANY : PSL_TYPE_ANY | PSL_TYPE_NO_STAR_RULE);
    psl_free_string(normalized);
    return result;
}

bool wk_hostIsIPAddress(CFStringRef host)
{
    // URL hosts carry brackets around IPv6; Security/CF cookie callers also supply bare literals.
    // Use the address grammar for both representations, including rejection of malformed numeric names.
    char text[INET6_ADDRSTRLEN + 2];
    if (!host || !CFStringGetCString(host, text, sizeof(text), kCFStringEncodingASCII)
        || strlen(text) != (size_t)CFStringGetLength(host))
        return false;
    size_t length = strlen(text);
    bool bracketed = length >= 2 && text[0] == '[' && text[length - 1] == ']';
    const char *address = text;
    if (bracketed) {
        text[length - 1] = 0;
        ++address;
    }
    struct in6_addr ipv6;
    if (inet_pton(AF_INET6, address, &ipv6) == 1)
        return true;
    struct in_addr ipv4;
    return !bracketed && inet_pton(AF_INET, address, &ipv4) == 1;
}

bool wk_domainIsPublicSuffix(CFStringRef domain)
{
    return wk_nameIsTopLevelDomain(domain);
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

// Cookie acceptance compares complete registrable domains, including multi-label/private PSL entries.
bool wk_hostsHaveDifferentRegistrableDomains(CFURLRef first, CFURLRef second)
{
    CFStringRef firstHost = first ? CFURLCopyHostName(first) : NULL;
    CFStringRef secondHost = second ? CFURLCopyHostName(second) : NULL;
    CFStringRef firstDomain = wk_copyRegistrableDomain(firstHost);
    CFStringRef secondDomain = wk_copyRegistrableDomain(secondHost);
    bool different = CFStringCompare(firstDomain, secondDomain, kCFCompareCaseInsensitive) != kCFCompareEqualTo;
    CFRelease(firstDomain);
    CFRelease(secondDomain);
    if (firstHost) CFRelease(firstHost);
    if (secondHost) CFRelease(secondHost);
    return different;
}
