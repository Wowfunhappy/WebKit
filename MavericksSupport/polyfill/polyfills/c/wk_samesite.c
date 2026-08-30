// See wk_samesite.h.
#include "wk_samesite.h"

#include "wk_hosts.h"
#include "wk_polyfill.h"

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
// A field this layer writes and cannot carry is a cookie this layer refuses, never a cookie stored
// with the field cut down to fit: "Strict" trimmed to "Str" reads as unrecognised, which is permissive.
#define WK_FIELD_CAP 256
#define WK_MAX_FIELDS 8
#define WK_MAX_KEY_LENGTH 8

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
        count = count * 10 + (c - '0');
        if (++digits > 2)
            return false;
        ++position;
    }
    if (!digits || count < 1 || count > WK_MAX_FIELDS)
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
        if (!thisKeyLength || thisKeyLength > WK_MAX_KEY_LENGTH)
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
        if (valueLength > WK_FIELD_CAP)
            return false;

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
    // A field is capped, and each escape is three characters for one byte, so the decoded form fits the
    // encoded length.
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

    CFMutableStringRef encoded = CFStringCreateMutable(NULL, 0);
    if (!encoded) {
        free(bytes);
        return NULL;
    }
    static const char hex[] = "0123456789ABCDEF";
    for (CFIndex i = 0; i < used; ++i) {
        UniChar out[3];
        if (wk_isUnreserved(bytes[i])) {
            out[0] = bytes[i];
            CFStringAppendCharacters(encoded, out, 1);
            continue;
        }
        out[0] = '%';
        out[1] = (UniChar)hex[(bytes[i] >> 4) & 0xF];
        out[2] = (UniChar)hex[bytes[i] & 0xF];
        CFStringAppendCharacters(encoded, out, 3);
    }
    free(bytes);
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

    CFStringRef encodedSameSite = wk_copyPercentEncoded(sameSite);
    CFStringRef encodedComment = comment ? wk_copyPercentEncoded(comment) : NULL;
    CFMutableStringRef blob = NULL;

    if (encodedSameSite && (!comment || encodedComment)
        && CFStringGetLength(encodedSameSite) <= WK_FIELD_CAP
        && (!encodedComment || CFStringGetLength(encodedComment) <= WK_FIELD_CAP)) {
        blob = CFStringCreateMutable(NULL, 0);
        if (blob) {
            CFStringAppendFormat(blob, NULL, CFSTR(WK_BLOB_PREFIX "%d"), encodedComment ? 2 : 1);
            if (encodedComment)
                CFStringAppendFormat(blob, NULL, CFSTR(" c=%@"), encodedComment);
            CFStringAppendFormat(blob, NULL, CFSTR(" ss=%@"), encodedSameSite);
        }
    }
    if (encodedSameSite)
        CFRelease(encodedSameSite);
    if (encodedComment)
        CFRelease(encodedComment);

    // Only this layer writes one of these, so a blob that does not read back is this layer's own bug --
    // and a cookie whose restriction did not survive the write reads as permissive. Checking it here
    // keeps that failure inside the gate that can still refuse the cookie.
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

wk_same_site_policy wk_sameSitePolicyOfComment(CFStringRef comment)
{
    CFRange range;
    if (!wk_blobScan(comment, "ss", &range) || range.location == kCFNotFound)
        return WK_SAME_SITE_NONE;

    // Longer than the longest value the modern constants name, so unrecognised either way.
    uint8_t value[16];
    CFIndex length = wk_decodeFieldInto(comment, range, value, (CFIndex)sizeof(value) - 1);
    if (length < 0)
        return WK_SAME_SITE_NONE;
    value[length] = 0;
    if (!strcasecmp((const char *)value, "strict"))
        return WK_SAME_SITE_STRICT;
    if (!strcasecmp((const char *)value, "lax"))
        return WK_SAME_SITE_LAX;
    return WK_SAME_SITE_NONE;
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
    CFRange value;
    long cookie;        // the cookie that owns it, or -1 for bytes that are no attribute at all
};

// Each occurrence costs a parse, so a field carrying more of them than a jar's worth is refused rather
// than parsed thousands of times -- and refused rather than stored unmarked, which would make the cap
// the way around the attribute.
#define WK_MAX_ATTRIBUTES 64

// The comment one occurrence is offered the chance to produce. A cookie whose own comment is this
// exact text makes an occurrence unattributable, which is refused rather than guessed at.
#define WK_PROBE_COMMENT "wk-attributing-this-one"

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
// classification below is what tells the two apart, by asking the parser. Answers -1 when there are
// more than |capacity| of them.
static long wk_findAttributes(CFStringRef header, struct wk_attribute *found, long capacity)
{
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
#define WK_AT(index) CFStringGetCharacterFromInlineBuffer(&buffer, (index))

    long count = 0;
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

        if (count >= capacity)
            return -1;
        found[count].isSameSite = isSameSite;
        found[count].name = name;
        found[count].value = CFRangeMake(valueStart, valueEnd - valueStart);
        found[count].whole = CFRangeMake(nameStart, valueEnd - nameStart);
        found[count].cookie = -1;
        ++count;
    }
    return count;
#undef WK_AT
}

// An attribute name 10.9's parser has no state for, so the attribute is dropped, and exactly as long as
// the name it stands in for, so every other offset in the field stays where it was.
static CFStringRef wk_copyInertName(CFIndex length)
{
    CFMutableStringRef name = CFStringCreateMutable(NULL, 0);
    if (!name)
        return NULL;
    CFStringAppend(name, CFSTR("wk"));
    for (CFIndex i = 2; i < length; ++i)
        CFStringAppend(name, CFSTR("x"));
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

// The one cookie of |cookies| whose comment is |text|: -1 for none, -2 when more than one is.
static CFIndex wk_indexOfCookieCommented(CFArrayRef cookies, CFStringRef text)
{
    CFIndex found = -1;
    for (CFIndex i = 0, count = CFArrayGetCount(cookies); i < count; ++i) {
        CFStringRef comment = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(cookies, i));
        bool matches = comment && CFEqual(comment, text);
        if (comment)
            CFRelease(comment);
        if (!matches)
            continue;
        if (found >= 0)
            return -2;
        found = i;
    }
    return found;
}

wk_samesite_header_disposition wk_sameSiteRewriteSetCookieHeader(CFStringRef header, CFURLRef url, CFStringRef *rewritten)
{
    *rewritten = NULL;
    if (!header || !CFStringGetLength(header) || !url)
        return WK_SAMESITE_HEADER_UNCHANGED;
    // What a field carrying no attribute costs: this one search.
    if (CFStringFind(header, CFSTR("samesite"), kCFCompareCaseInsensitive).location == kCFNotFound)
        return WK_SAMESITE_HEADER_UNCHANGED;

    struct wk_attribute attributes[WK_MAX_ATTRIBUTES];
    struct wk_edit edits[WK_MAX_ATTRIBUTES];
    CFStringRef inertNames[WK_MAX_ATTRIBUTES];
    long attributeCount = wk_findAttributes(header, attributes, WK_MAX_ATTRIBUTES);
    if (attributeCount < 0) {
        syslog(LOG_ERR, "[wk_polyfill] SameSite: a Set-Cookie field carries more than %d SameSite and Comment "
                        "attributes; refusing it rather than storing its cookies unrestricted.", WK_MAX_ATTRIBUTES);
        return WK_SAMESITE_HEADER_REFUSED;
    }
    bool anySameSite = false;
    for (long i = 0; i < attributeCount; ++i) {
        inertNames[i] = NULL;
        anySameSite = anySameSite || attributes[i].isSameSite;
    }
    if (!anySameSite)
        return WK_SAMESITE_HEADER_UNCHANGED;

    wk_samesite_header_disposition disposition = WK_SAMESITE_HEADER_REFUSED;
    CFArrayRef original = wk_parseSetCookieHeader(header, url);
    CFArrayRef baseline = NULL;
    CFStringRef inert = NULL;
    CFStringRef *blobs = NULL;
    CFStringRef *commentFields = NULL;
    CFStringRef *originalComments = NULL;
    long *firstSameSiteFor = NULL;
    CFIndex cookieCount = original ? CFArrayGetCount(original) : 0;
    long editCount = 0;

    if (!cookieCount) {
        disposition = WK_SAMESITE_HEADER_UNCHANGED;
        goto done;
    }

    for (long i = 0; i < attributeCount; ++i) {
        inertNames[i] = wk_copyInertName(attributes[i].name.length);
        if (!inertNames[i])
            goto done;
    }

    // Attribution runs against a copy of the field with every one of these names replaced by one the
    // parser drops, so no cookie in it carries a comment and each occurrence in turn can be the only
    // thing in the whole field that produces one. Each name keeps its length, so the offsets measured
    // above still address the same bytes.
    for (long i = 0; i < attributeCount; ++i) {
        edits[i].range = attributes[i].name;
        edits[i].replacement = inertNames[i];
    }
    inert = wk_copyHeaderWithEdits(header, edits, attributeCount);
    baseline = inert ? wk_parseSetCookieHeader(inert, url) : NULL;
    if (!baseline || CFArrayGetCount(baseline) != cookieCount)
        goto done;

    // The cookie that comes back carrying the probe comment owns those bytes. Bytes that are no
    // attribute -- a ';' inside a quoted value, which 10.9's parser keeps whole -- change that value
    // instead, which the comparison sees, so they are left exactly as they were.
    for (long k = 0; k < attributeCount; ++k) {
        edits[0].range = attributes[k].whole;
        edits[0].replacement = CFSTR("Comment=" WK_PROBE_COMMENT);
        CFStringRef probeHeader = wk_copyHeaderWithEdits(inert, edits, 1);
        CFArrayRef probe = probeHeader ? wk_parseSetCookieHeader(probeHeader, url) : NULL;
        CFIndex owner = -1;
        bool ambiguous = false;
        if (probe && wk_cookiesMatchApartFromComment(baseline, probe)) {
            owner = wk_indexOfCookieCommented(probe, CFSTR(WK_PROBE_COMMENT));
            ambiguous = owner == -2;
        }
        if (probeHeader)
            CFRelease(probeHeader);
        if (probe)
            CFRelease(probe);
        if (ambiguous) {
            syslog(LOG_ERR, "[wk_polyfill] SameSite: a Set-Cookie field's attributes cannot be told apart; "
                            "refusing it rather than storing its cookies unrestricted.");
            goto done;
        }
        attributes[k].cookie = (long)owner;
    }

    blobs = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    commentFields = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    originalComments = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    firstSameSiteFor = (long *)calloc((size_t)cookieCount, sizeof(long));
    if (!blobs || !commentFields || !originalComments || !firstSameSiteFor)
        goto done;
    for (CFIndex c = 0; c < cookieCount; ++c)
        originalComments[c] = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(original, c));

    for (CFIndex c = 0; c < cookieCount; ++c) {
        long lastSameSite = -1;
        firstSameSiteFor[c] = -1;
        for (long i = 0; i < attributeCount; ++i) {
            if (attributes[i].cookie != (long)c || !attributes[i].isSameSite)
                continue;
            if (firstSameSiteFor[c] < 0)
                firstSameSiteFor[c] = i;
            lastSameSite = i;
        }
        // A cookie this field gave no attribute to keeps every byte it came with.
        if (firstSameSiteFor[c] < 0)
            continue;

        // RFC 6265 4.1.2: where an attribute repeats, the last one is the cookie's. The comment is the
        // one the parser already made of the field as the server sent it.
        CFStringRef sameSite = CFStringCreateWithSubstring(NULL, header, attributes[lastSameSite].value);
        if (sameSite) {
            blobs[c] = wk_sameSiteCommentCreate(sameSite, originalComments[c]);
            CFRelease(sameSite);
        }
        if (!blobs[c]) {
            syslog(LOG_ERR, "[wk_polyfill] SameSite: a cookie's attribute does not fit the field that carries "
                            "it; refusing the header rather than storing the cookie unrestricted.");
            goto done;
        }
        commentFields[c] = CFStringCreateWithFormat(NULL, NULL, CFSTR("Comment=%@"), blobs[c]);
        if (!commentFields[c])
            goto done;
    }

    for (CFIndex c = 0; c < cookieCount; ++c) {
        if (firstSameSiteFor[c] < 0)
            continue;
        for (long i = 0; i < attributeCount; ++i) {
            if (attributes[i].cookie != (long)c)
                continue;
            if (i == firstSameSiteFor[c]) {
                edits[editCount].range = attributes[i].whole;
                edits[editCount].replacement = commentFields[c];
            } else {
                edits[editCount].range = attributes[i].name;
                edits[editCount].replacement = inertNames[i];
            }
            ++editCount;
        }
    }

    {
        CFStringRef result = wk_copyHeaderWithEdits(header, edits, editCount);
        CFArrayRef reparsed = result ? wk_parseSetCookieHeader(result, url) : NULL;
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
        } else if (result) {
            CFRelease(result);
            syslog(LOG_ERR, "[wk_polyfill] SameSite: carrying the attribute would have changed a cookie; "
                            "refusing the header.");
        }
    }

done:
    for (long i = 0; i < attributeCount; ++i) {
        if (inertNames[i])
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
    free(blobs);
    free(commentFields);
    free(originalComments);
    free(firstSameSiteFor);
    if (inert)
        CFRelease(inert);
    if (baseline)
        CFRelease(baseline);
    if (original)
        CFRelease(original);
    return disposition;
}
