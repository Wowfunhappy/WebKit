// See wk_samesite.h.
#include "wk_samesite.h"

#include "wk_hosts.h"
#include "wk_polyfill.h"
#include "wk_symbols.h"

#include <stdlib.h>
#include <string.h>
#include <sys/syslog.h>

// CFNetwork's own cookie parser and accessors, exported on 10.9 but declared in no public header and
// absent from the build SDK's stub library. The parser is reached here rather than through
// +[NSHTTPCookie cookiesWithResponseHeaderFields:forURL:], because that selector is itself replaced by
// this layer. Resolved through the layer rather than linked, because libpolyfill.a is force-loaded into
// images that do not link CFNetwork.
typedef const struct OpaqueCFHTTPCookie *WKHTTPCookieRef;
WK_SYSTEM_FN("CFNetwork", CFArrayRef, CFHTTPCookieCreateWithResponseHeaderFields, (CFAllocatorRef, CFDictionaryRef, CFURLRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyName, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyValue, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyDomain, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyPath, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyComment, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", CFAbsoluteTime, CFHTTPCookieGetExpirationTime, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", uint32_t, CFHTTPCookieGetFlags, (WKHTTPCookieRef));

// ---------------------------------------------------------------------------------------------------
// The encoded Comment.
//
//     wk:<field count> <key>=<percent-encoded value> ...
//
// Keys ascend, so one policy has one encoding and re-encoding a cookie leaves it equal to itself. The
// field count is what a comment of a server's own that happens to begin "wk:" fails, so it is handed
// back as the comment it is rather than misread. Percent-encoding keeps ';' and ',' -- which end an
// attribute value in the header grammar -- and the ' ' and '=' this format is punctuated with out of
// every value.
// ---------------------------------------------------------------------------------------------------

#define WK_BLOB_PREFIX "wk:"
#define WK_BLOB_PREFIX_LENGTH 3

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
                if (position + 2 >= length || !wk_isHexDigit(WK_AT(position + 1)) || !wk_isHexDigit(WK_AT(position + 2)))
                    return false;
                position += 3;
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

// Decodes the field at |range| into |bytes|. Answers the byte count, or -1 when it does not fit.
static CFIndex wk_decodeFieldInto(CFStringRef comment, CFRange range, uint8_t *bytes, CFIndex capacity)
{
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(comment, &buffer, range);
    CFIndex written = 0;
    for (CFIndex i = 0; i < range.length; ) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (written >= capacity)
            return -1;
        if (c == '%') {
            bytes[written++] = (uint8_t)((wk_hexValue(CFStringGetCharacterFromInlineBuffer(&buffer, i + 1)) << 4)
                | wk_hexValue(CFStringGetCharacterFromInlineBuffer(&buffer, i + 2)));
            i += 3;
            continue;
        }
        bytes[written++] = (uint8_t)c;
        ++i;
    }
    return written;
}

static CFStringRef wk_copyDecodedField(CFStringRef comment, CFRange range)
{
    // Each escape is three characters for one byte and every other character is one, so the decoded
    // form fits the encoded length.
    CFIndex capacity = range.length + 1;
    uint8_t *bytes = (uint8_t *)malloc((size_t)capacity);
    if (!bytes)
        return NULL;
    CFIndex written = wk_decodeFieldInto(comment, range, bytes, capacity);
    CFStringRef decoded = written < 0 ? NULL
        : CFStringCreateWithBytes(NULL, bytes, written, kCFStringEncodingUTF8, false);
    free(bytes);
    return decoded;
}

static CFStringRef wk_copyPercentEncoded(CFStringRef value)
{
    CFIndex length = CFStringGetLength(value);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    uint8_t *bytes = (uint8_t *)malloc((size_t)capacity);
    if (!bytes)
        return NULL;
    CFIndex used = 0;
    CFIndex converted = CFStringGetBytes(value, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, false,
                                         bytes, capacity, &used);
    if (converted != length) {
        free(bytes);
        return NULL;
    }

    // Encoded in one pass into a byte buffer and minted as one string: this runs per cookie value,
    // and the output is pure ASCII.
    uint8_t *out = (uint8_t *)malloc((size_t)(used ? used : 1) * 3);
    if (!out) {
        free(bytes);
        return NULL;
    }
    static const char hex[] = "0123456789ABCDEF";
    CFIndex outLength = 0;
    for (CFIndex i = 0; i < used; ++i) {
        if (wk_isUnreserved(bytes[i])) {
            out[outLength++] = bytes[i];
            continue;
        }
        out[outLength++] = '%';
        out[outLength++] = (uint8_t)hex[(bytes[i] >> 4) & 0xF];
        out[outLength++] = (uint8_t)hex[bytes[i] & 0xF];
    }
    free(bytes);
    CFStringRef encoded = CFStringCreateWithBytes(NULL, out, outLength, kCFStringEncodingASCII, false);
    free(out);
    return encoded;
}

static bool wk_fieldReadsBackAs(CFStringRef blob, const char *key, CFStringRef expected)
{
    CFRange range;
    if (!wk_blobScan(blob, key, &range))
        return false;
    if (!expected)
        return range.location == kCFNotFound;
    if (range.location == kCFNotFound)
        return false;
    CFStringRef decoded = wk_copyDecodedField(blob, range);
    bool equal = decoded && CFEqual(decoded, expected);
    if (decoded)
        CFRelease(decoded);
    return equal;
}

CFStringRef wk_sameSiteCommentCreate(CFStringRef sameSite, CFStringRef comment)
{
    if (!sameSite)
        return comment ? (CFStringRef)CFRetain(comment) : NULL;

    // Text that does not convert -- a lone surrogate, which a script can put in a cookie's comment --
    // has no encoding, so there is nothing to carry and the caller stores the cookie without it.
    CFStringRef encodedSameSite = wk_copyPercentEncoded(sameSite);
    CFStringRef encodedComment = comment ? wk_copyPercentEncoded(comment) : NULL;
    CFMutableStringRef blob = NULL;
    if (encodedSameSite && (!comment || encodedComment)) {
        blob = CFStringCreateMutable(NULL, 0);
        if (!blob)
            wk_patch_fail(kSameSiteEncoding, "a comment could not be allocated");
        CFStringAppendFormat(blob, NULL, CFSTR(WK_BLOB_PREFIX "%d"), encodedComment ? 2 : 1);
        if (encodedComment)
            CFStringAppendFormat(blob, NULL, CFSTR(" c=%@"), encodedComment);
        CFStringAppendFormat(blob, NULL, CFSTR(" ss=%@"), encodedSameSite);
    }
    if (encodedSameSite)
        CFRelease(encodedSameSite);
    if (encodedComment)
        CFRelease(encodedComment);

    // A blob that does not read back carries nothing this layer could read either, so the cookie is
    // stored the way 10.9 stores every cookie: without the restriction.
    if (blob && (!wk_fieldReadsBackAs(blob, "ss", sameSite) || !wk_fieldReadsBackAs(blob, "c", comment))) {
        CFRelease(blob);
        blob = NULL;
    }
    return blob;
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

// The policy |value| names: a value the modern constants do not name is unspecified, which is
// permissive (RFC 6265bis 5.3.7), and so is "None" itself.
static wk_same_site_policy wk_policyOfValueBytes(const char *value)
{
    if (!strcasecmp(value, "strict"))
        return WK_SAME_SITE_STRICT;
    if (!strcasecmp(value, "lax"))
        return WK_SAME_SITE_LAX;
    return WK_SAME_SITE_NONE;
}

// Longer than the longest value the modern constants name, so a longer one is unrecognised either way.
#define WK_POLICY_VALUE_CAPACITY 16

wk_same_site_policy wk_sameSitePolicyOfValue(CFStringRef value)
{
    char bytes[WK_POLICY_VALUE_CAPACITY];
    if (!value || !CFStringGetCString(value, bytes, (CFIndex)sizeof(bytes), kCFStringEncodingUTF8))
        return WK_SAME_SITE_NONE;
    return wk_policyOfValueBytes(bytes);
}

wk_same_site_policy wk_sameSitePolicyOfComment(CFStringRef comment)
{
    CFRange range;
    if (!wk_blobScan(comment, "ss", &range) || range.location == kCFNotFound)
        return WK_SAME_SITE_NONE;

    uint8_t value[WK_POLICY_VALUE_CAPACITY];
    CFIndex length = wk_decodeFieldInto(comment, range, value, (CFIndex)sizeof(value) - 1);
    if (length < 0)
        return WK_SAME_SITE_NONE;
    value[length] = 0;
    return wk_policyOfValueBytes((const char *)value);
}

bool wk_sameSiteAllows(wk_same_site_policy policy, bool isSameSite, bool isTopLevelNavigation, bool isSafeMethod)
{
    if (policy == WK_SAME_SITE_NONE || isSameSite)
        return true;
    if (policy == WK_SAME_SITE_STRICT)
        return false;
    return isTopLevelNavigation && isSafeMethod;
}

bool wk_sameSiteMethodIsSafe(CFStringRef method)
{
    if (!method)
        return true;
    return CFEqual(method, CFSTR("GET")) || CFEqual(method, CFSTR("HEAD"))
        || CFEqual(method, CFSTR("OPTIONS")) || CFEqual(method, CFSTR("TRACE"));
}

// ---------------------------------------------------------------------------------------------------
// Same-site, re-derived at every hop.
//
// CFNetwork carries a request's cookie-policy properties across an internal redirect verbatim while the
// URL changes host, so the stamp says what the first hop was, not what this one is. Only the comparison
// answers for this hop.
// ---------------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------------
// The Set-Cookie header field on its way into the jar.
//
// The attribute is alive only in the raw header, so the encoding goes on there, before the parse. What
// makes that safe is that the parser decides everything: each occurrence is offered to it alone, and
// the cookie that comes back carrying a comment is the cookie that occurrence belongs to. A run of
// bytes that reads like the attribute but is not one -- inside a quoted value, say -- produces no such
// cookie and is left exactly as it was.
// ---------------------------------------------------------------------------------------------------

// One occurrence of an attribute name in a Set-Cookie header field.
struct wk_attribute {
    bool isSameSite;    // false: Comment
    CFRange name;       // replaced in place by a name of the same length, which the parser drops
    CFRange whole;      // the name, the '=' and the value
    CFRange value;      // the value alone, without the space the grammar allows around it
    long cookie;        // the cookie that owns it, or -1 for bytes that are no attribute at all
};

// The comment an occurrence is offered the chance to produce, one text per occurrence.
#define WK_PROBE_PREFIX "wk-attributing-"

struct wk_edit {
    CFRange range;
    CFStringRef replacement;
};

static bool wk_isHeaderSpace(UniChar c) { return c == ' ' || c == '\t'; }

static bool wk_rangeEqualsLowercase(CFStringInlineBuffer *buffer, CFRange range, const char *text)
{
    if (range.length != (CFIndex)strlen(text))
        return false;
    for (CFIndex i = 0; i < range.length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(buffer, range.location + i);
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (c != (UniChar)text[i])
            return false;
    }
    return true;
}

// Every attribute of a Set-Cookie header field opens with ';'. A ';' inside a quoted value opens one
// too as far as this scan is concerned -- 10.9's parser keeps such a value whole (measured) -- and the
// attribution below is what tells the two apart, by asking the parser. The caller owns the result.
static struct wk_attribute *wk_copyAttributes(CFStringRef header, long *outCount)
{
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
#define WK_AT(index) CFStringGetCharacterFromInlineBuffer(&buffer, (index))

    struct wk_attribute *found = NULL;
    long count = 0, capacity = 0;
    CFIndex position = 0;
    while (position < length) {
        if (WK_AT(position) != ';') {
            ++position;
            continue;
        }
        ++position;
        while (position < length && wk_isHeaderSpace(WK_AT(position)))
            ++position;

        CFIndex nameStart = position;
        while (position < length) {
            UniChar c = WK_AT(position);
            if (c == '=' || c == ';' || c == ',')
                break;
            ++position;
        }
        CFIndex nameEnd = position;
        while (nameEnd > nameStart && wk_isHeaderSpace(WK_AT(nameEnd - 1)))
            --nameEnd;

        CFRange name = CFRangeMake(nameStart, nameEnd - nameStart);
        bool isSameSite = wk_rangeEqualsLowercase(&buffer, name, "samesite");
        if (!isSameSite && !wk_rangeEqualsLowercase(&buffer, name, "comment"))
            continue;

        CFIndex valueStart = nameEnd, valueEnd = nameEnd;
        if (position < length && WK_AT(position) == '=') {
            valueStart = ++position;
            while (position < length) {
                UniChar c = WK_AT(position);
                if (c == ';' || c == ',')
                    break;
                ++position;
            }
            valueEnd = position;
        }
        CFIndex trimmedStart = valueStart, trimmedEnd = valueEnd;
        while (trimmedStart < trimmedEnd && wk_isHeaderSpace(WK_AT(trimmedStart)))
            ++trimmedStart;
        while (trimmedEnd > trimmedStart && wk_isHeaderSpace(WK_AT(trimmedEnd - 1)))
            --trimmedEnd;

        if (count == capacity) {
            capacity = capacity ? capacity * 2 : 16;
            struct wk_attribute *grown = (struct wk_attribute *)realloc(found, (size_t)capacity * sizeof(*found));
            if (!grown)
                wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's attributes did not fit in memory");
            found = grown;
        }
        found[count].isSameSite = isSameSite;
        found[count].name = name;
        found[count].value = CFRangeMake(trimmedStart, trimmedEnd - trimmedStart);
        found[count].whole = CFRangeMake(nameStart, valueEnd - nameStart);
        found[count].cookie = -1;
        ++count;
    }
    *outCount = count;
    return found;
#undef WK_AT
}

// An attribute name 10.9's parser has no state for, so the attribute is dropped, and exactly as long as
// the name it stands in for, so every other offset in the field stays where it was.
static CFStringRef wk_copyInertName(CFIndex length)
{
    UniChar stack[64];
    UniChar *chars = length <= 64 ? stack : (UniChar *)malloc((size_t)length * sizeof(UniChar));
    if (!chars)
        return NULL;
    chars[0] = 'w';
    if (length > 1)
        chars[1] = 'k';
    for (CFIndex i = 2; i < length; ++i)
        chars[i] = 'x';
    CFStringRef name = CFStringCreateWithCharacters(NULL, chars, length);
    if (chars != stack)
        free(chars);
    return name;
}

static CFStringRef wk_copyHeaderWithEdits(CFStringRef header, struct wk_edit *edits, long count)
{
    // Applied from the end, so an edit that changes length leaves the offsets of the ones still to come
    // where they were measured.
    for (long i = 1; i < count; ++i) {
        struct wk_edit edit = edits[i];
        long j = i;
        while (j > 0 && edits[j - 1].range.location < edit.range.location) {
            edits[j] = edits[j - 1];
            --j;
        }
        edits[j] = edit;
    }
    CFMutableStringRef result = CFStringCreateMutableCopy(NULL, 0, header);
    if (!result)
        return NULL;
    for (long i = 0; i < count; ++i)
        CFStringReplace(result, edits[i].range, edits[i].replacement);
    return result;
}

static CFArrayRef wk_parseSetCookieHeader(CFStringRef header, CFURLRef url)
{
    const void *key = (const void *)CFSTR("Set-Cookie");
    const void *value = (const void *)header;
    CFDictionaryRef fields = CFDictionaryCreate(NULL, &key, &value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!fields)
        return NULL;
    CFArrayRef cookies = WK_SYSTEM(CFHTTPCookieCreateWithResponseHeaderFields)
        ? WK_SYSTEM(CFHTTPCookieCreateWithResponseHeaderFields)(NULL, fields, url) : NULL;
    CFRelease(fields);
    return cookies;
}

static bool wk_equalOrBothNull(CFStringRef a, CFStringRef b)
{
    if (!a || !b)
        return a == b;
    return CFEqual(a, b);
}

// Everything the record carries except the comment, which is the field this rewrite exists to change.
static bool wk_cookiesMatchApartFromComment(CFArrayRef a, CFArrayRef b)
{
    if (!a || !b)
        return false;
    CFIndex count = CFArrayGetCount(a);
    if (count != CFArrayGetCount(b))
        return false;
    for (CFIndex i = 0; i < count; ++i) {
        WKHTTPCookieRef first = (WKHTTPCookieRef)CFArrayGetValueAtIndex(a, i);
        WKHTTPCookieRef second = (WKHTTPCookieRef)CFArrayGetValueAtIndex(b, i);
        CFStringRef fields[8];
        fields[0] = WK_SYSTEM(CFHTTPCookieCopyName)(first);
        fields[1] = WK_SYSTEM(CFHTTPCookieCopyName)(second);
        fields[2] = WK_SYSTEM(CFHTTPCookieCopyValue)(first);
        fields[3] = WK_SYSTEM(CFHTTPCookieCopyValue)(second);
        fields[4] = WK_SYSTEM(CFHTTPCookieCopyDomain)(first);
        fields[5] = WK_SYSTEM(CFHTTPCookieCopyDomain)(second);
        fields[6] = WK_SYSTEM(CFHTTPCookieCopyPath)(first);
        fields[7] = WK_SYSTEM(CFHTTPCookieCopyPath)(second);
        bool equal = wk_equalOrBothNull(fields[0], fields[1]) && wk_equalOrBothNull(fields[2], fields[3])
            && wk_equalOrBothNull(fields[4], fields[5]) && wk_equalOrBothNull(fields[6], fields[7])
            && WK_SYSTEM(CFHTTPCookieGetFlags)(first) == WK_SYSTEM(CFHTTPCookieGetFlags)(second)
            && WK_SYSTEM(CFHTTPCookieGetExpirationTime)(first) == WK_SYSTEM(CFHTTPCookieGetExpirationTime)(second);
        for (int f = 0; f < 8; ++f) {
            if (fields[f])
                CFRelease(fields[f]);
        }
        if (!equal)
            return false;
    }
    return true;
}

// The occurrence |comment| is the probe of, or -1 when it is not one.
static long wk_probedIndexOfComment(CFStringRef comment, long attributeCount)
{
    if (!comment)
        return -1;
    CFIndex length = CFStringGetLength(comment);
    CFIndex prefix = (CFIndex)strlen(WK_PROBE_PREFIX);
    if (length <= prefix)
        return -1;
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(comment, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i < prefix; ++i) {
        if (CFStringGetCharacterFromInlineBuffer(&buffer, i) != (UniChar)WK_PROBE_PREFIX[i])
            return -1;
    }
    long index = 0;
    for (CFIndex i = prefix; i < length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (c < '0' || c > '9' || index > attributeCount)
            return -1;
        index = index * 10 + (c - '0');
    }
    return index < attributeCount ? index : -1;
}

// Attributes each of |pending| to the cookie whose bytes carry it. One parse answers for the whole
// list: every occurrence in it is offered as the only comment its cookie can take, and 10.9's parser
// keeps the FIRST comment a cookie is given (measured), so a cookie that comes back carrying
// occurrence k's probe owns k. The occurrences a round does not attribute are offered again without
// the ones it did, so the cost is one parse per attribute a single cookie carries rather than one per
// attribute in the field. A list whose probe changes any other field of any cookie holds bytes that
// are no attribute -- a ';' inside a quoted value -- and is split until each of those stands alone;
// they are attributed to no cookie and keep every byte they came with.
static bool wk_attributeOccurrences(CFStringRef inert, CFURLRef url, struct wk_attribute *attributes,
                                    long attributeCount, long *pending, long pendingCount,
                                    CFArrayRef baseline)
{
    while (pendingCount > 0) {
        struct wk_edit *edits = (struct wk_edit *)calloc((size_t)pendingCount, sizeof(*edits));
        CFStringRef *probes = (CFStringRef *)calloc((size_t)pendingCount, sizeof(*probes));
        if (!edits || !probes)
            wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's probes did not fit in memory");
        for (long i = 0; i < pendingCount; ++i) {
            probes[i] = CFStringCreateWithFormat(NULL, NULL, CFSTR("Comment=" WK_PROBE_PREFIX "%ld"), pending[i]);
            if (!probes[i])
                wk_patch_fail(kSameSiteEncoding, "a probe comment could not be made");
            edits[i].range = attributes[pending[i]].whole;
            edits[i].replacement = probes[i];
        }
        CFStringRef probedHeader = wk_copyHeaderWithEdits(inert, edits, pendingCount);
        if (!probedHeader)
            wk_patch_fail(kSameSiteEncoding, "a field carrying the probes could not be made");
        CFArrayRef probed = wk_parseSetCookieHeader(probedHeader, url);
        bool clean = wk_cookiesMatchApartFromComment(baseline, probed);
        bool ambiguous = false;
        long attributed = 0;
        for (CFIndex c = 0, cookies = clean ? CFArrayGetCount(probed) : 0; c < cookies; ++c) {
            CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(probed, c));
            long k = wk_probedIndexOfComment(comment, attributeCount);
            if (comment)
                CFRelease(comment);
            if (k < 0)
                continue;
            // Two cookies answering for one occurrence is a field this layer cannot account for, and
            // what it cannot account for it does not touch.
            if (attributes[k].cookie >= 0)
                ambiguous = true;
            attributes[k].cookie = (long)c;
            ++attributed;
        }
        for (long i = 0; i < pendingCount; ++i)
            CFRelease(probes[i]);
        free(probes);
        free(edits);
        CFRelease(probedHeader);
        if (probed)
            CFRelease(probed);
        if (ambiguous)
            return false;

        if (!clean) {
            if (pendingCount == 1)
                return true;
            long half = pendingCount / 2;
            return wk_attributeOccurrences(inert, url, attributes, attributeCount, pending, half, baseline)
                && wk_attributeOccurrences(inert, url, attributes, attributeCount, pending + half,
                                           pendingCount - half, baseline);
        }
        // A round that attributes nothing has reached bytes no cookie claims: a segment the parser
        // drops carries its attributes nowhere.
        if (!attributed)
            return true;
        long remaining = 0;
        for (long i = 0; i < pendingCount; ++i) {
            if (attributes[pending[i]].cookie < 0)
                pending[remaining++] = pending[i];
        }
        pendingCount = remaining;
    }
    return true;
}

// A field that trips one of the failure reports below trips it on every response from that origin,
// and syslog is a synchronous write to syslogd; one report per message site carries the diagnostic.
#define WK_SAMESITE_REPORT_ONCE(...) do { \
        static bool wk_reported; \
        if (!wk_reported) { \
            wk_reported = true; \
            syslog(__VA_ARGS__); \
        } \
    } while (0)

// Does the field name "samesite", ASCII-case-insensitively? Runs on every cookie-setting response
// over fields that are routinely multi-kilobyte, so it is a byte scan rather than CFStringFind's
// Unicode-folding search.
static bool wk_headerNamesSameSite(CFStringRef header)
{
    static const char wanted[] = "samesite";
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i + 8 <= length; ++i) {
        CFIndex j = 0;
        while (j < 8) {
            UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i + j);
            if (c >= 'A' && c <= 'Z')
                c += 'a' - 'A';
            if (c != (UniChar)wanted[j])
                break;
            ++j;
        }
        if (j == 8)
            return true;
    }
    return false;
}

wk_samesite_header_disposition wk_sameSiteRewriteSetCookieHeader(CFStringRef header, CFURLRef url, CFStringRef *rewritten)
{
    *rewritten = NULL;
    if (!header || !CFStringGetLength(header) || !url)
        return WK_SAMESITE_HEADER_UNCHANGED;
    // What a field carrying no attribute costs: this one scan.
    if (!wk_headerNamesSameSite(header))
        return WK_SAMESITE_HEADER_UNCHANGED;

    long attributeCount = 0;
    struct wk_attribute *attributes = wk_copyAttributes(header, &attributeCount);
    bool anySameSite = false;
    for (long i = 0; i < attributeCount; ++i)
        anySameSite = anySameSite || attributes[i].isSameSite;

    wk_samesite_header_disposition disposition = WK_SAMESITE_HEADER_UNCHANGED;
    CFArrayRef original = anySameSite ? wk_parseSetCookieHeader(header, url) : NULL;
    CFIndex cookieCount = original ? CFArrayGetCount(original) : 0;
    CFStringRef *inertNames = NULL, *blobs = NULL, *commentFields = NULL, *originalComments = NULL;
    long *pending = NULL, *firstOwned = NULL, *lastSameSite = NULL;
    struct wk_edit *edits = NULL;
    CFStringRef inert = NULL;
    CFArrayRef baseline = NULL;
    long editCount = 0;

    if (!cookieCount)
        goto done;

    inertNames = (CFStringRef *)calloc((size_t)attributeCount, sizeof(CFStringRef));
    pending = (long *)calloc((size_t)attributeCount, sizeof(long));
    edits = (struct wk_edit *)calloc((size_t)attributeCount, sizeof(struct wk_edit));
    blobs = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    commentFields = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    originalComments = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    firstOwned = (long *)calloc((size_t)cookieCount, sizeof(long));
    lastSameSite = (long *)calloc((size_t)cookieCount, sizeof(long));
    if (!inertNames || !pending || !edits || !blobs || !commentFields || !originalComments
        || !firstOwned || !lastSameSite)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's working set did not fit in memory");

    for (long i = 0; i < attributeCount; ++i) {
        inertNames[i] = wk_copyInertName(attributes[i].name.length);
        if (!inertNames[i])
            wk_patch_fail(kSameSiteEncoding, "an inert attribute name could not be made");
        edits[i].range = attributes[i].name;
        edits[i].replacement = inertNames[i];
        pending[i] = i;
    }

    if (attributeCount == 1 && cookieCount == 1) {
        // One attribute and one cookie — the overwhelmingly common field — can only pair one way,
        // so the inert copy, the baseline parse and the probe rounds have nothing to decide. The
        // reparse verification below still rejects a field whose "attribute" is bytes inside a
        // quoted value: the edit changes the cookie, the reparse shows it, and the field goes to
        // the parser as the server sent it.
        attributes[0].cookie = 0;
    } else {
    // Attribution runs against a copy of the field with every one of these names replaced by one the
    // parser drops, so no cookie in it carries a comment and a probe is the only thing that can give
    // one. Each name keeps its length, so the offsets measured above still address the same bytes.
    inert = wk_copyHeaderWithEdits(header, edits, attributeCount);
    if (!inert)
        wk_patch_fail(kSameSiteEncoding, "a field with inert attribute names could not be made");
    baseline = wk_parseSetCookieHeader(inert, url);
    if (!baseline || CFArrayGetCount(baseline) != cookieCount) {
        WK_SAMESITE_REPORT_ONCE(LOG_ERR, "[wk_polyfill] SameSite: a Set-Cookie field's attribute names cannot be told from "
                        "its cookies; leaving the field as the server sent it.");
        goto done;
    }

    if (!wk_attributeOccurrences(inert, url, attributes, attributeCount, pending, attributeCount, baseline)) {
        WK_SAMESITE_REPORT_ONCE(LOG_ERR, "[wk_polyfill] SameSite: a Set-Cookie field's attributes cannot be told apart; "
                        "leaving the field as the server sent it.");
        goto done;
    }
    }

    for (CFIndex c = 0; c < cookieCount; ++c)
        originalComments[c] = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(original, c));

    for (CFIndex c = 0; c < cookieCount; ++c) {
        firstOwned[c] = -1;
        lastSameSite[c] = -1;
        for (long i = 0; i < attributeCount; ++i) {
            if (attributes[i].cookie != (long)c)
                continue;
            if (firstOwned[c] < 0)
                firstOwned[c] = i;
            if (attributes[i].isSameSite)
                lastSameSite[c] = i;
        }
        if (lastSameSite[c] < 0)
            continue;

        // RFC 6265 4.1.2: where an attribute repeats, the last one is the cookie's.
        CFStringRef value = CFStringCreateWithSubstring(NULL, header, attributes[lastSameSite[c]].value);
        if (!value)
            wk_patch_fail(kSameSiteEncoding, "an attribute's value could not be read");
        wk_same_site_policy policy = wk_sameSitePolicyOfValue(value);
        // A restriction is carried; a value that restricts nothing is left for 10.9 to drop as the
        // unknown attribute it is, which stores the cookie exactly as this field would have without
        // this layer. "None" and a value the modern constants do not name are both permissive.
        if (policy == WK_SAME_SITE_NONE) {
            CFRelease(value);
            lastSameSite[c] = -1;
            continue;
        }
        blobs[c] = wk_sameSiteCommentCreate(value, originalComments[c]);
        CFRelease(value);
        // Text this layer cannot encode leaves the cookie as the server sent it, which is the cookie
        // 10.9 stores for every restriction it is given.
        if (!blobs[c]) {
            WK_SAMESITE_REPORT_ONCE(LOG_ERR, "[wk_polyfill] SameSite: a cookie's restriction cannot be carried in a "
                            "comment; leaving its field as the server sent it.");
            lastSameSite[c] = -1;
            continue;
        }
        commentFields[c] = CFStringCreateWithFormat(NULL, NULL, CFSTR("Comment=%@"), blobs[c]);
        if (!commentFields[c])
            wk_patch_fail(kSameSiteEncoding, "a comment field could not be allocated");
    }

    for (CFIndex c = 0; c < cookieCount; ++c) {
        if (lastSameSite[c] < 0)
            continue;
        for (long i = 0; i < attributeCount; ++i) {
            if (attributes[i].cookie != (long)c)
                continue;
            bool carriesTheBlob = i == firstOwned[c];
            edits[editCount].range = carriesTheBlob ? attributes[i].whole : attributes[i].name;
            edits[editCount].replacement = carriesTheBlob ? commentFields[c] : inertNames[i];
            ++editCount;
        }
    }
    // Every SameSite this field carries restricts nothing, so the field is already what should be
    // parsed.
    if (!editCount)
        goto done;

    {
        CFStringRef result = wk_copyHeaderWithEdits(header, edits, editCount);
        if (!result)
            wk_patch_fail(kSameSiteEncoding, "the field carrying the attribute could not be made");
        CFArrayRef reparsed = wk_parseSetCookieHeader(result, url);
        bool intact = wk_cookiesMatchApartFromComment(original, reparsed);
        // Every cookie's comment is checked too, so a cookie either carries the field this rewrite gave
        // it or the comment the server sent, and nothing else.
        for (CFIndex c = 0; intact && c < cookieCount; ++c) {
            CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(reparsed, c));
            intact = wk_equalOrBothNull(comment, blobs[c] ? blobs[c] : originalComments[c]);
            if (comment)
                CFRelease(comment);
        }
        if (reparsed)
            CFRelease(reparsed);
        if (intact) {
            *rewritten = result;
            disposition = WK_SAMESITE_HEADER_REWRITTEN;
        } else {
            CFRelease(result);
            // The field reaches the parser as the server sent it, so every cookie it sets is stored:
            // the restriction is what is lost, and 10.9 without this layer loses it for every cookie.
            WK_SAMESITE_REPORT_ONCE(LOG_ERR, "[wk_polyfill] SameSite: carrying the attribute would have changed a cookie; "
                            "leaving the field as the server sent it.");
        }
    }

done:
    for (long i = 0; i < attributeCount; ++i) {
        if (inertNames && inertNames[i])
            CFRelease(inertNames[i]);
    }
    for (CFIndex c = 0; c < cookieCount; ++c) {
        if (blobs && blobs[c])
            CFRelease(blobs[c]);
        if (commentFields && commentFields[c])
            CFRelease(commentFields[c]);
        if (originalComments && originalComments[c])
            CFRelease(originalComments[c]);
    }
    free(inertNames);
    free(pending);
    free(edits);
    free(blobs);
    free(commentFields);
    free(originalComments);
    free(firstOwned);
    free(lastSameSite);
    free(attributes);
    if (inert)
        CFRelease(inert);
    if (baseline)
        CFRelease(baseline);
    if (original)
        CFRelease(original);
    return disposition;
}
