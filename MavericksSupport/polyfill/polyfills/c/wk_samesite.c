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
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyComment, (WKHTTPCookieRef));
WK_SYSTEM_FN("CFNetwork", double, CFHTTPCookieGetExpirationTime, (CFTypeRef));
// The Copy forms, not the Get forms: 10.9 says of its own accessors "CFHTTPCookieGetDomain is
// deprecated in this OS build. Clients must call CFHTTPCookieCopyDomain or the NS equivalent instead or
// risk leaks", and each Get call leaks the string it answers with.
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyName, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", CFStringRef, CFHTTPCookieCopyPath, (CFTypeRef));
WK_SYSTEM_FN("CFNetwork", Boolean, CFHTTPCookieIsSecure, (CFTypeRef));

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

CFStringRef wk_cookieBlobCreate(CFStringRef sameSite, CFStringRef created, CFStringRef comment)
{
    if (!sameSite && !created)
        return comment ? (CFStringRef)CFRetain(comment) : NULL;

    // Text that does not convert -- a lone surrogate, which a script can put in a cookie's comment --
    // has no encoding, so there is nothing to carry and the caller stores the cookie without it.
    CFStringRef encodedSameSite = sameSite ? wk_copyPercentEncoded(sameSite) : NULL;
    CFStringRef encodedCreated = created ? wk_copyPercentEncoded(created) : NULL;
    CFStringRef encodedComment = comment ? wk_copyPercentEncoded(comment) : NULL;
    CFMutableStringRef blob = NULL;
    if ((!sameSite || encodedSameSite) && (!created || encodedCreated) && (!comment || encodedComment)) {
        int fields = (encodedComment ? 1 : 0) + (encodedCreated ? 1 : 0) + (encodedSameSite ? 1 : 0);
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
    }
    if (encodedSameSite)
        CFRelease(encodedSameSite);
    if (encodedCreated)
        CFRelease(encodedCreated);
    if (encodedComment)
        CFRelease(encodedComment);

    // A blob that does not read back carries nothing this layer could read either, so the cookie is
    // stored the way 10.9 stores every cookie: without the fields it could not carry.
    if (blob && (!wk_fieldReadsBackAs(blob, "ss", sameSite) || !wk_fieldReadsBackAs(blob, "cr", created)
        || !wk_fieldReadsBackAs(blob, "c", comment))) {
        CFRelease(blob);
        blob = NULL;
    }
    return blob;
}

CFStringRef wk_sameSiteCommentCreate(CFStringRef sameSite, CFStringRef comment)
{
    return wk_cookieBlobCreate(sameSite, NULL, comment);
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
static wk_same_site_policy wk_policyOfValueBytes(const char *value)
{
    if (!strcasecmp(value, "strict"))
        return WK_SAME_SITE_STRICT;
    if (!strcasecmp(value, "none"))
        return WK_SAME_SITE_NONE;
    return WK_SAME_SITE_LAX;
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

// The longest suffix of |host| and |otherHost| that begins at a label boundary in both, as a count of
// labels. Two hosts that share nothing answer 0, and a host and a subdomain of it answer the shorter
// one's label count.
static CFIndex wk_sharedLabelCount(CFStringRef host, CFStringRef otherHost)
{
    CFIndex length = CFStringGetLength(host);
    CFIndex otherLength = CFStringGetLength(otherHost);
    CFIndex shared = 0;
    CFIndex i = length, j = otherLength;
    while (i > 0 && j > 0) {
        CFIndex labelStart = i, otherLabelStart = j;
        while (labelStart > 0 && CFStringGetCharacterAtIndex(host, labelStart - 1) != '.')
            --labelStart;
        while (otherLabelStart > 0 && CFStringGetCharacterAtIndex(otherHost, otherLabelStart - 1) != '.')
            --otherLabelStart;
        if (i - labelStart != j - otherLabelStart)
            break;
        CFStringRef label = CFStringCreateWithSubstring(NULL, host, CFRangeMake(labelStart, i - labelStart));
        CFStringRef otherLabel = CFStringCreateWithSubstring(NULL, otherHost, CFRangeMake(otherLabelStart, j - otherLabelStart));
        bool same = label && otherLabel && CFStringCompare(label, otherLabel, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
        if (label)
            CFRelease(label);
        if (otherLabel)
            CFRelease(otherLabel);
        if (!same)
            break;
        ++shared;
        i = labelStart ? labelStart - 1 : 0;
        j = otherLabelStart ? otherLabelStart - 1 : 0;
        if (!labelStart || !otherLabelStart)
            break;
    }
    return shared;
}

// Whether two hosts have nothing in common but a top-level domain.
//
// HTTPCookieStorage::setCookies and ::setCookiesWithResponseHeaderFields take a cookie under
// NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain when isURLInMainDocumentDomain says so, which is
// "the two hosts' common ancestor is not a top-level domain" answered from a 2013 table: `test`, `app`
// and `dev` are not in it, so a third party under any of them is read as the main document's own
// domain and its cookie is stored. A common ancestor of one label is a top-level domain whatever the
// table holds, so that is the answer given here; a longer ancestor is left to 10.9's own reading.
bool wk_hostsShareOnlyATopLevelDomain(CFURLRef url, CFURLRef mainDocumentURL)
{
    CFStringRef host = url ? CFURLCopyHostName(url) : NULL;
    CFStringRef mainHost = mainDocumentURL ? CFURLCopyHostName(mainDocumentURL) : NULL;
    bool onlyATopLevelDomain = false;
    if (host && mainHost && CFStringCompare(host, mainHost, kCFCompareCaseInsensitive) != kCFCompareEqualTo)
        onlyATopLevelDomain = wk_sharedLabelCount(host, mainHost) <= 1;
    if (host)
        CFRelease(host);
    if (mainHost)
        CFRelease(mainHost);
    return onlyATopLevelDomain;
}

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


struct wk_edit {
    CFRange range;
    CFStringRef replacement;
};

static bool wk_isHeaderSpace(UniChar c) { return c == ' ' || c == '\t'; }

static void wk_appendRange(CFMutableStringRef out, CFStringRef source, CFRange range)
{
    if (!range.length)
        return;
    CFStringRef text = CFStringCreateWithSubstring(NULL, source, range);
    if (!text)
        wk_patch_fail(kSameSiteEncoding, "a set-cookie-string's text could not be read");
    CFStringAppend(out, text);
    CFRelease(text);
}

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

// Every attribute of a Set-Cookie header field opens with a ';' outside a double-quoted value: 10.9's
// parser reads a="x;y" as one cookie whose value holds the semicolon (measured), so a ';' inside the
// quotes opens nothing here either. The caller owns the result.
static struct wk_attribute *wk_copyAttributes(CFStringRef header, long *outCount)
{
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
#define WK_AT(index) CFStringGetCharacterFromInlineBuffer(&buffer, (index))

    struct wk_attribute *found = NULL;
    long count = 0, capacity = 0;
    CFIndex position = 0;
    // A ';' inside a double-quoted value begins no attribute: 10.9 reads a="x;y" as one cookie whose
    // value holds the semicolon.
    bool inQuotes = false;
    while (position < length) {
        UniChar here = WK_AT(position);
        if (here == '"') {
            inQuotes = !inQuotes;
            ++position;
            continue;
        }
        if (inQuotes || here != ';') {
            ++position;
            continue;
        }
        ++position;
        while (position < length && wk_isHeaderSpace(WK_AT(position)))
            ++position;

        CFIndex nameStart = position;
        while (position < length) {
            UniChar c = WK_AT(position);
            if (c == '"')
                inQuotes = !inQuotes;
            else if (!inQuotes && (c == '=' || c == ';' || c == ','))
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
                if (c == '"')
                    inQuotes = !inQuotes;
                else if (!inQuotes && (c == ';' || c == ','))
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

// The set-cookie-strings a folded Set-Cookie field carries, as ranges over the field.
//
// CFNetwork folds several Set-Cookie headers into one field joined with ", " -- the fold happens in the
// HTTP message parser, so by the time any cookie code runs the field is one string and the boundary is
// a comma like any other. A cookie-value may itself hold a comma, so these are the boundaries 10.9's
// own parser reads, measured against it: a comma outside double quotes, followed by at least one SP
// (an HTAB there divides nothing), then a non-empty token that reaches an '=' before any ';', ',' or
// '"'. So "a=1,2, b=3" is the two cookies "a=1,2" and "b=3"; "a=1,b=2" is one, the comma carrying no
// space; "a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT" is one, the date's comma reaching no '='; and
// "a=\"x, y=z\"" is one, the comma being quoted. The caller owns the result.
CFRange *wk_copySetCookieRanges(CFStringRef header, CFIndex *outCount)
{
    *outCount = 0;
    CFIndex length = header ? CFStringGetLength(header) : 0;
    if (!length)
        return NULL;

    CFRange *ranges = (CFRange *)calloc((size_t)length + 1, sizeof(CFRange));
    if (!ranges)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's cookie ranges did not fit in memory");

    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));

    CFIndex count = 0, start = 0, i = 0;
    bool inQuotes = false;
    while (i < length) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (c == '"') {
            inQuotes = !inQuotes;
            ++i;
            continue;
        }
        if (inQuotes || c != ',') {
            ++i;
            continue;
        }

        // What follows: the fold's SP, then a cookie-name and its '=', begin a new cookie.
        CFIndex after = i + 1;
        while (after < length && CFStringGetCharacterFromInlineBuffer(&buffer, after) == ' ')
            ++after;
        CFIndex token = after;
        while (token < length) {
            UniChar t = CFStringGetCharacterFromInlineBuffer(&buffer, token);
            if (t == '=' || t == ';' || t == ',' || t == '"')
                break;
            ++token;
        }
        bool beginsACookie = after > i + 1 && token > after && token < length
            && CFStringGetCharacterFromInlineBuffer(&buffer, token) == '=';
        if (!beginsACookie) {
            ++i;
            continue;
        }

        ranges[count++] = CFRangeMake(start, i - start);
        start = after;
        i = after;
    }
    if (start < length)
        ranges[count++] = CFRangeMake(start, length - start);

    *outCount = count;
    return ranges;
}

// A CTL other than HTAB: %x00-08, %x0A-1F or %x7F.
static bool wk_rangeHasControlCharacter(CFStringRef header, CFRange range)
{
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, range);
    for (CFIndex i = 0; i < range.length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (c != '\t' && (c <= 0x1f || c == 0x7f))
            return true;
    }
    return false;
}

// RFC 6265 5.1.4: a cookie-path matches a request-path when the two are equal, or when the cookie-path
// is a prefix of the request-path and either the cookie-path ends in '/' or the request-path continues
// with one. 10.9 tests only the prefix -- HTTPCookieStorage::lookupAndCopyCookies is a strlen bound and
// a strncmp -- so a cookie whose Path is /cook is served at /cookies/anything.
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
bool wk_hasControlCharacter(CFStringRef text)
{
    CFIndex length = text ? CFStringGetLength(text) : 0;
    if (!length)
        return false;
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(text, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i < length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i);
        if (c == '\t')
            continue;
        if (c <= 0x1f || c == 0x7f)
            return true;
    }
    return false;
}

// RFC 6265bis 5.5: a set-cookie-string carrying a CTL other than HTAB is ignored, its attributes
// included. The cookies of |header| that carry none, folded back into one field. NULL when every cookie
// in the field carries one, which is a field that sets nothing. The caller owns the result.
CFStringRef wk_copyFieldWithoutControlCookies(CFStringRef header)
{
    CFIndex count = 0;
    CFRange *ranges = wk_copySetCookieRanges(header, &count);
    if (!ranges)
        return NULL;

    CFMutableStringRef kept = CFStringCreateMutable(NULL, 0);
    if (!kept)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's surviving cookies did not fit in memory");
    CFIndex keptCount = 0;
    for (CFIndex c = 0; c < count; ++c) {
        if (wk_rangeHasControlCharacter(header, ranges[c]))
            continue;
        if (keptCount++)
            CFStringAppend(kept, CFSTR(", "));
        CFStringRef one = CFStringCreateWithSubstring(NULL, header, ranges[c]);
        if (!one)
            wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's surviving cookie could not be read");
        CFStringAppend(kept, one);
        CFRelease(one);
    }
    free(ranges);

    if (keptCount)
        return kept;
    CFRelease(kept);
    return NULL;
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

// ---------------------------------------------------------------------------------------------------
// The ceiling on a cookie's lifetime.
//
// RFC 6265bis 4.1.2.1 caps a cookie at 400 days from the moment it is set, and modern CFNetwork
// enforces it; 10.9 keeps whatever the field names, so a response can plant a cookie that outlives the
// machine. The cap is expressed by appending Max-Age to the set-cookie-string that exceeds it: Max-Age
// takes precedence over Expires (RFC 6265 5.3), so one appended attribute caps a cookie however its
// lifetime was written, and the cookie's own bytes are otherwise left exactly as the server sent them.
//
// Which cookies exceed it is answered by 10.9's own parser rather than by reading the attributes here:
// the parser resolves Max-Age against Expires, tolerates the date formats it tolerates, and reports one
// expiration time. A cookie with no expiry at all is a session cookie, which has no lifetime to cap.
static const double kMaximumCookieLifetime = WK_MAXIMUM_COOKIE_LIFETIME_SECONDS;

// Does the field name a lifetime at all? Runs on every cookie-setting response, so it is a byte scan.
static bool wk_headerNamesALifetime(CFStringRef header)
{
    static const char * const wanted[] = { "max-age", "expires" };
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
    for (int w = 0; w < 2; ++w) {
        CFIndex wantedLength = (CFIndex)strlen(wanted[w]);
        for (CFIndex i = 0; i + wantedLength <= length; ++i) {
            CFIndex j = 0;
            while (j < wantedLength) {
                UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i + j);
                if (c >= 'A' && c <= 'Z')
                    c += 'a' - 'A';
                if (c != (UniChar)wanted[w][j])
                    break;
                ++j;
            }
            if (j == wantedLength)
                return true;
        }
    }
    return false;
}

// The value bytes of the cookie's first attribute of this name, or a location of kCFNotFound when it
// carries none. The first rather than the last: 10.9's parser keeps the first Max-Age a set-cookie-string
// carries and ignores the ones after it (measured), so that is the one whose value decides the lifetime,
// and the same reading answers whether a Domain attribute is there at all.
static CFRange wk_attributeValueRange(CFStringRef header, CFRange cookie, const char *wanted)
{
    CFIndex wantedLength = (CFIndex)strlen(wanted);
    CFRange none = CFRangeMake(kCFNotFound, 0);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, cookie);
#define WK_COOKIE_AT(index) CFStringGetCharacterFromInlineBuffer(&buffer, (index))

    bool quoted = false;
    for (CFIndex i = 0; i < cookie.length; ++i) {
        UniChar here = WK_COOKIE_AT(i);
        if (here == '"') {
            quoted = !quoted;
            continue;
        }
        // A ';' inside a double-quoted value begins no attribute: 10.9 reads a="x;y" as one cookie whose
        // value holds the semicolon, so a scan that anchored there would rewrite bytes of the value.
        if (here != ';' || quoted)
            continue;
        CFIndex name = i + 1;
        while (name < cookie.length && wk_isHeaderSpace(WK_COOKIE_AT(name)))
            ++name;
        CFIndex j = 0;
        while (j < wantedLength && name + j < cookie.length) {
            UniChar c = WK_COOKIE_AT(name + j);
            if (c >= 'A' && c <= 'Z')
                c += 'a' - 'A';
            if (c != (UniChar)wanted[j])
                break;
            ++j;
        }
        if (j < wantedLength)
            continue;
        CFIndex equals = name + wantedLength;
        while (equals < cookie.length && wk_isHeaderSpace(WK_COOKIE_AT(equals)))
            ++equals;
        if (equals >= cookie.length || WK_COOKIE_AT(equals) != '=')
            continue;
        CFIndex value = equals + 1;
        while (value < cookie.length && wk_isHeaderSpace(WK_COOKIE_AT(value)))
            ++value;
        CFIndex end = value;
        bool valueQuoted = false;
        while (end < cookie.length) {
            UniChar c = WK_COOKIE_AT(end);
            if (c == '"')
                valueQuoted = !valueQuoted;
            else if (c == ';' && !valueQuoted)
                break;
            ++end;
        }
        while (end > value && wk_isHeaderSpace(WK_COOKIE_AT(end - 1)))
            --end;
        return CFRangeMake(cookie.location + value, end - value);
    }
    return none;
#undef WK_COOKIE_AT
}

// ---------------------------------------------------------------------------------------------------
// The two things a cookie must be to be stored at all, beyond the domain rules already applied.
//
// A cookie with the Secure attribute belongs to a secure origin and a non-secure one may not set it
// (RFC 6265bis 4.1.2.5); a cookie named __Secure-... promises exactly that, and one named __Host-...
// promises it plus a path of "/" and no Domain attribute (4.1.3). A cookie that breaks its own promise
// is ignored. Modern CFNetwork enforces all three, matching the prefixes CASE-SENSITIVELY -- __SeCuRe-
// is an ordinary name there, which is what upstream's own expectations for
// imported/w3c/web-platform-tests/cookies/prefix record -- and 10.9 enforces none of them (measured:
// every spelling of every violation is stored).
//
// Whether the cookie carried a Domain attribute is read off the set-cookie-string it was parsed from,
// not off the domain the parse produced: 10.9 marks a domain cookie with a leading dot for a named host
// but not for an IPv4 literal (measured: Domain=127.0.0.1 comes back as 127.0.0.1, the same as a
// host-only cookie), so the parsed domain cannot answer the question. An empty Domain= is no attribute
// (RFC 6265bis 5.4, and 10.9 reads it as the host).
static bool wk_urlIsSecureForCookies(CFURLRef url)
{
    CFStringRef scheme = url ? CFURLCopyScheme(url) : NULL;
    bool secure = scheme
        && (CFStringCompare(scheme, CFSTR("https"), kCFCompareCaseInsensitive) == kCFCompareEqualTo
            || CFStringCompare(scheme, CFSTR("wss"), kCFCompareCaseInsensitive) == kCFCompareEqualTo);
    if (scheme)
        CFRelease(scheme);
    return secure;
}

// What a field that could not name a refusable cookie costs: this one scan. A cookie is refusable only
// if it carries the Secure attribute (which a non-secure origin may not set, and which both prefixes
// require) or names the __Host- prefix, which is refused without Secure as well.
static bool wk_headerCouldNameARefusableCookie(CFStringRef header)
{
    static const char secure[] = "secure";
    static const char host[] = "__Host-";
    CFIndex length = CFStringGetLength(header);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(header, &buffer, CFRangeMake(0, length));
    for (CFIndex i = 0; i < length; ++i) {
        CFIndex j = 0;
        while (j < 6 && i + j < length) {
            UniChar c = CFStringGetCharacterFromInlineBuffer(&buffer, i + j);
            if (c >= 'A' && c <= 'Z')
                c += 'a' - 'A';
            if (c != (UniChar)secure[j])
                break;
            ++j;
        }
        if (j == 6)
            return true;
        j = 0;
        while (j < 7 && i + j < length
            && CFStringGetCharacterFromInlineBuffer(&buffer, i + j) == (UniChar)host[j])
            ++j;
        if (j == 7)
            return true;
    }
    return false;
}

bool wk_cookieMayBeSet(CFStringRef name, bool isSecure, CFStringRef path, bool hasDomainAttribute, CFURLRef url)
{
    bool fromSecureOrigin = wk_urlIsSecureForCookies(url);
    if (isSecure && !fromSecureOrigin)
        return false;

    if (!name)
        return true;
    bool host = CFStringHasPrefix(name, CFSTR("__Host-"));
    if (!host && !CFStringHasPrefix(name, CFSTR("__Secure-")))
        return true;

    if (!isSecure || !fromSecureOrigin)
        return false;
    if (!host)
        return true;

    if (!path || CFStringCompare(path, CFSTR("/"), 0) != kCFCompareEqualTo)
        return false;
    return !hasDomainAttribute;
}

static bool wk_parsedCookieMayBeSet(CFTypeRef cookie, CFStringRef setCookieString, CFURLRef url)
{
    if (!cookie)
        return true;
    CFRange domain = wk_attributeValueRange(setCookieString, CFRangeMake(0, CFStringGetLength(setCookieString)), "domain");
    CFStringRef name = WK_SYSTEM(CFHTTPCookieCopyName)(cookie);
    CFStringRef path = WK_SYSTEM(CFHTTPCookieCopyPath)(cookie);
    bool mayBeSet = wk_cookieMayBeSet(name, WK_SYSTEM(CFHTTPCookieIsSecure)(cookie), path,
        domain.location != kCFNotFound && domain.length > 0, url);
    if (name)
        CFRelease(name);
    if (path)
        CFRelease(path);
    return mayBeSet;
}

// The same field with the cookies that may not be set left out, or NULL when every cookie in it may be.
// An empty result is a field that sets nothing, which the caller must not pass on.
CFStringRef wk_cookieFieldWithoutRefusedCookiesCreate(CFStringRef header, CFURLRef url, bool *outSetsNothing)
{
    *outSetsNothing = false;
    if (!header || !CFStringGetLength(header) || !url || !wk_headerCouldNameARefusableCookie(header))
        return NULL;

    CFIndex cookieCount = 0;
    CFRange *cookies = wk_copySetCookieRanges(header, &cookieCount);
    if (!cookieCount) {
        free(cookies);
        return NULL;
    }

    CFMutableStringRef kept = CFStringCreateMutable(NULL, 0);
    if (!kept)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field could not be rebuilt");
    long keptCount = 0, refusedCount = 0;
    for (CFIndex c = 0; c < cookieCount; ++c) {
        CFStringRef one = CFStringCreateWithSubstring(NULL, header, cookies[c]);
        CFArrayRef parsed = one ? wk_parseSetCookieHeader(one, url) : NULL;
        CFTypeRef cookie = parsed && CFArrayGetCount(parsed) == 1 ? CFArrayGetValueAtIndex(parsed, 0) : NULL;
        if (!one)
            wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's surviving cookie could not be read");
        bool refused = cookie && !wk_parsedCookieMayBeSet(cookie, one, url);
        if (refused)
            ++refusedCount;
        else {
            if (keptCount)
                CFStringAppend(kept, CFSTR(", "));
            CFStringAppend(kept, one);
            ++keptCount;
        }
        if (parsed)
            CFRelease(parsed);
        if (one)
            CFRelease(one);
    }
    free(cookies);

    if (!refusedCount) {
        CFRelease(kept);
        return NULL;
    }
    *outSetsNothing = !keptCount;
    return kept;
}

// The attributes of one set-cookie-string, as ranges over it. RFC 6265bis 5.2 trims OWS -- SP or HTAB
// -- from around a cookie's name and value and around every attribute name and value.
struct wk_one_attribute {
    CFRange name;
    CFRange value;      // length 0 with location kCFNotFound when the attribute carries no '='
    CFRange rawName;    // the same two before any trimming, which is what 10.9's parser is handed
    CFRange rawValue;
    int recognised;     // index into kRecognisedAttributes, or -1
};

// The attribute names RFC 6265bis 5.6 acts on. A name outside this set is ignored rather than
// deduplicated, which is also what keeps the scans below linear over a field that came off the wire.
static const char *const kRecognisedAttributes[] = {
    "expires", "max-age", "domain", "path", "secure", "httponly", "samesite"
};
#define WK_RECOGNISED_ATTRIBUTE_COUNT ((int)(sizeof(kRecognisedAttributes) / sizeof(kRecognisedAttributes[0])))

static int wk_recognisedAttributeIndex(CFStringInlineBuffer *buffer, CFRange name)
{
    for (int i = 0; i < WK_RECOGNISED_ATTRIBUTE_COUNT; ++i) {
        if (wk_rangeEqualsLowercase(buffer, name, kRecognisedAttributes[i]))
            return i;
    }
    return -1;
}

static CFRange wk_rangeTrimmed(CFStringInlineBuffer *buffer, CFRange range, bool includeTab)
{
    while (range.length) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(buffer, range.location);
        if (c != ' ' && !(includeTab && c == '\t'))
            break;
        ++range.location;
        --range.length;
    }
    while (range.length) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(buffer, range.location + range.length - 1);
        if (c != ' ' && !(includeTab && c == '\t'))
            break;
        --range.length;
    }
    return range;
}

// |raw| split at its first '=' into a name and a value, each trimmed of OWS. A slice with no '=' is one
// token, which the caller emits as it stands: whether 10.9 reads it as a name or as a value is 10.9's
// own reading and this rule does not change it.
static void wk_splitAtFirstEquals(CFStringInlineBuffer *buffer, CFRange raw,
                                  CFRange *outRawName, CFRange *outRawValue,
                                  CFRange *outName, CFRange *outValue)
{
    *outRawName = raw;
    *outRawValue = CFRangeMake(kCFNotFound, 0);
    for (CFIndex j = raw.location; j < raw.location + raw.length; ++j) {
        if (CFStringGetCharacterFromInlineBuffer(buffer, j) != '=')
            continue;
        *outRawName = CFRangeMake(raw.location, j - raw.location);
        *outRawValue = CFRangeMake(j + 1, raw.location + raw.length - (j + 1));
        break;
    }
    *outName = wk_rangeTrimmed(buffer, *outRawName, true);
    *outValue = outRawValue->location == kCFNotFound ? *outRawValue : wk_rangeTrimmed(buffer, *outRawValue, true);
}

// Whether the OWS trim of |raw| differs from the SP-only trim 10.9's parser applies, which is what
// leaves an HTAB-bearing name or value unrecognised there.
static bool wk_htabWouldSurvive(CFStringInlineBuffer *buffer, CFRange raw, CFRange trimmed)
{
    if (raw.location == kCFNotFound)
        return false;
    CFRange sp = wk_rangeTrimmed(buffer, raw, false);
    return sp.location != trimmed.location || sp.length != trimmed.length;
}

// The attributes of |one|, split on the ';' that opens each (never one inside a double-quoted value).
// *outPairEnd is where the name-value pair ends, which is where the first attribute's ';' sits, or the
// length when the cookie carries no attribute at all.
static struct wk_one_attribute *wk_copyOneCookiesAttributes(CFStringRef one, CFStringInlineBuffer *buffer,
                                                            CFIndex *outPairEnd, long *outCount)
{
    CFIndex length = CFStringGetLength(one);
    *outCount = 0;
    *outPairEnd = length;

    bool inQuotes = false;
    for (CFIndex i = 0; i < length; ++i) {
        UniChar c = CFStringGetCharacterFromInlineBuffer(buffer, i);
        if (c == '"') {
            inQuotes = !inQuotes;
            continue;
        }
        if (!inQuotes && c == ';') {
            *outPairEnd = i;
            break;
        }
    }
    if (*outPairEnd == length)
        return NULL;

    long count = 0, capacity = 8;
    struct wk_one_attribute *found = (struct wk_one_attribute *)malloc((size_t)capacity * sizeof(*found));
    if (!found)
        wk_patch_fail(kSameSiteEncoding, "a set-cookie-string's attributes could not be collected");

    CFIndex start = *outPairEnd + 1;
    inQuotes = false;
    for (CFIndex i = start; i <= length; ++i) {
        UniChar c = i < length ? CFStringGetCharacterFromInlineBuffer(buffer, i) : (UniChar)';';
        if (i < length && c == '"') {
            inQuotes = !inQuotes;
            continue;
        }
        if (i < length && (inQuotes || c != ';'))
            continue;

        struct wk_one_attribute attribute;
        wk_splitAtFirstEquals(buffer, CFRangeMake(start, i - start),
                              &attribute.rawName, &attribute.rawValue, &attribute.name, &attribute.value);
        attribute.recognised = wk_recognisedAttributeIndex(buffer, attribute.name);
        if (count == capacity) {
            capacity *= 2;
            struct wk_one_attribute *grown = (struct wk_one_attribute *)realloc(found, (size_t)capacity * sizeof(*found));
            if (!grown)
                wk_patch_fail(kSameSiteEncoding, "a set-cookie-string's attributes could not be collected");
            found = grown;
        }
        found[count] = attribute;
        ++count;
        start = i + 1;
    }
    *outCount = count;
    return found;
}

// RFC 6265bis 5.2 processes a set-cookie-string's attributes in order and 5.6 takes the last attribute
// of each recognised name; 10.9's parser keeps the first ("test=8; Path=/qux; Path=/" stores /qux here
// and / everywhere else, measured). 5.2 also trims OWS -- SP or HTAB -- from around the cookie's name
// and value and around every attribute name and value, where 10.9 trims only SP: "\tpath\t=\t/x" names
// no attribute there, and one HTAB after a cookie's value makes it drop every attribute the cookie
// carries, so a "Secure; Path=/" cookie arrives non-secure on the default path. The same
// set-cookie-string held to both, or NULL when it already reads that way.
static CFStringRef wk_setCookieStringWithLastAttributeWinningCreate(CFStringRef one)
{
    CFIndex length = CFStringGetLength(one);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer(one, &buffer, CFRangeMake(0, length));

    CFIndex pairEnd = 0;
    long count = 0;
    struct wk_one_attribute *attributes = wk_copyOneCookiesAttributes(one, &buffer, &pairEnd, &count);

    CFRange rawPairName, rawPairValue, pairName, pairValue;
    wk_splitAtFirstEquals(&buffer, CFRangeMake(0, pairEnd), &rawPairName, &rawPairValue, &pairName, &pairValue);

    bool rewrite = wk_htabWouldSurvive(&buffer, rawPairName, pairName)
        || wk_htabWouldSurvive(&buffer, rawPairValue, pairValue);

    // The last attribute of each recognised name; every earlier one of that name is superseded.
    long last[WK_RECOGNISED_ATTRIBUTE_COUNT];
    for (int i = 0; i < WK_RECOGNISED_ATTRIBUTE_COUNT; ++i)
        last[i] = -1;
    for (long i = 0; i < count; ++i) {
        if (attributes[i].recognised < 0)
            continue;
        if (last[attributes[i].recognised] >= 0)
            rewrite = true;
        last[attributes[i].recognised] = i;
        if (wk_htabWouldSurvive(&buffer, attributes[i].rawName, attributes[i].name)
            || wk_htabWouldSurvive(&buffer, attributes[i].rawValue, attributes[i].value))
            rewrite = true;
    }
    if (!rewrite) {
        free(attributes);
        return NULL;
    }

    CFMutableStringRef out = CFStringCreateMutable(NULL, 0);
    if (!out)
        wk_patch_fail(kSameSiteEncoding, "a set-cookie-string could not be rebuilt");
    wk_appendRange(out, one, pairName);
    if (rawPairValue.location != kCFNotFound) {
        CFStringAppend(out, CFSTR("="));
        wk_appendRange(out, one, pairValue);
    }

    for (long i = 0; i < count; ++i) {
        if (attributes[i].recognised >= 0 && last[attributes[i].recognised] != i)
            continue;
        CFStringAppend(out, CFSTR("; "));
        wk_appendRange(out, one, attributes[i].name);
        if (attributes[i].value.location == kCFNotFound)
            continue;
        CFStringAppend(out, CFSTR("="));
        wk_appendRange(out, one, attributes[i].value);
    }
    free(attributes);
    return out;
}

// The same field with every set-cookie-string in it held to that rule, or NULL when none of them needs
// it.
CFStringRef wk_cookieFieldWithLastAttributeWinningCreate(CFStringRef header)
{
    if (!header || !CFStringGetLength(header))
        return NULL;

    CFIndex cookieCount = 0;
    CFRange *cookies = wk_copySetCookieRanges(header, &cookieCount);
    if (!cookieCount) {
        free(cookies);
        return NULL;
    }

    CFMutableStringRef rebuilt = CFStringCreateMutable(NULL, 0);
    if (!rebuilt)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field could not be rebuilt");
    long rewritten = 0;
    for (CFIndex c = 0; c < cookieCount; ++c) {
        CFStringRef one = CFStringCreateWithSubstring(NULL, header, cookies[c]);
        if (!one)
            wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's cookie could not be read");
        CFStringRef canonical = wk_setCookieStringWithLastAttributeWinningCreate(one);
        if (canonical)
            ++rewritten;
        if (c)
            CFStringAppend(rebuilt, CFSTR(", "));
        CFStringAppend(rebuilt, canonical ? canonical : one);
        if (canonical)
            CFRelease(canonical);
        CFRelease(one);
    }
    free(cookies);

    if (!rewritten) {
        CFRelease(rebuilt);
        return NULL;
    }
    return rebuilt;
}

CFStringRef wk_cookieLifetimeCappedHeaderCreate(CFStringRef header, CFURLRef url)
{
    if (!header || !CFStringGetLength(header) || !url || !wk_headerNamesALifetime(header))
        return NULL;

    CFIndex cookieCount = 0;
    CFRange *cookies = wk_copySetCookieRanges(header, &cookieCount);
    if (!cookieCount) {
        free(cookies);
        return NULL;
    }

    struct wk_edit *edits = (struct wk_edit *)calloc((size_t)cookieCount, sizeof(struct wk_edit));
    if (!edits)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's lifetime edits did not fit in memory");

    double ceiling = CFAbsoluteTimeGetCurrent() + kMaximumCookieLifetime;
    CFStringRef cappedSeconds = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), (int)WK_MAXIMUM_COOKIE_LIFETIME_SECONDS);
    CFStringRef cappedAttribute = cappedSeconds ? CFStringCreateWithFormat(NULL, NULL, CFSTR("; Max-Age=%@"), cappedSeconds) : NULL;
    if (!cappedSeconds || !cappedAttribute)
        wk_patch_fail(kSameSiteEncoding, "the lifetime ceiling could not be written");
    long editCount = 0;
    for (CFIndex c = 0; c < cookieCount; ++c) {
        CFStringRef one = CFStringCreateWithSubstring(NULL, header, cookies[c]);
        CFArrayRef parsed = one ? wk_parseSetCookieHeader(one, url) : NULL;
        CFTypeRef cookie = parsed && CFArrayGetCount(parsed) == 1 ? CFArrayGetValueAtIndex(parsed, 0) : NULL;
        if (cookie && WK_SYSTEM(CFHTTPCookieGetExpirationTime)(cookie) > ceiling) {
            // A cookie that names a Max-Age has that value replaced -- the pass ahead of this one has
            // already reduced a repeated attribute to its last occurrence, so there is one to replace.
            // One whose lifetime comes from Expires takes an appended Max-Age, which decides the
            // lifetime over the date it carries (RFC 6265 5.3, and measured on this parser).
            CFRange maxAge = wk_attributeValueRange(header, cookies[c], "max-age");
            if (maxAge.location != kCFNotFound) {
                edits[editCount].range = maxAge;
                edits[editCount].replacement = (CFStringRef)CFRetain(cappedSeconds);
            } else {
                edits[editCount].range = CFRangeMake(cookies[c].location + cookies[c].length, 0);
                edits[editCount].replacement = (CFStringRef)CFRetain(cappedAttribute);
            }
            ++editCount;
        }
        if (parsed)
            CFRelease(parsed);
        if (one)
            CFRelease(one);
    }

    CFStringRef capped = editCount ? wk_copyHeaderWithEdits(header, edits, editCount) : NULL;
    for (long i = 0; i < editCount; ++i)
        CFRelease(edits[i].replacement);
    CFRelease(cappedAttribute);
    CFRelease(cappedSeconds);
    free(edits);
    free(cookies);
    return capped;
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
    CFIndex cookieCount = 0;
    CFRange *cookies = wk_copySetCookieRanges(header, &cookieCount);
    CFStringRef *inertNames = NULL, *blobs = NULL, *commentFields = NULL, *originalComments = NULL;
    long *firstOwned = NULL, *lastSameSite = NULL;
    struct wk_edit *edits = NULL;
    long editCount = 0;

    if (!anySameSite || !cookieCount)
        goto done;

    inertNames = (CFStringRef *)calloc((size_t)attributeCount, sizeof(CFStringRef));
    edits = (struct wk_edit *)calloc((size_t)attributeCount, sizeof(struct wk_edit));
    blobs = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    commentFields = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    originalComments = (CFStringRef *)calloc((size_t)cookieCount, sizeof(CFStringRef));
    firstOwned = (long *)calloc((size_t)cookieCount, sizeof(long));
    lastSameSite = (long *)calloc((size_t)cookieCount, sizeof(long));
    if (!inertNames || !edits || !blobs || !commentFields || !originalComments
        || !firstOwned || !lastSameSite)
        wk_patch_fail(kSameSiteEncoding, "a Set-Cookie field's working set did not fit in memory");

    for (long i = 0; i < attributeCount; ++i) {
        inertNames[i] = wk_copyInertName(attributes[i].name.length);
        if (!inertNames[i])
            wk_patch_fail(kSameSiteEncoding, "an inert attribute name could not be made");
    }

    // An attribute belongs to the cookie whose bytes contain it.
    for (long i = 0; i < attributeCount; ++i) {
        attributes[i].cookie = -1;
        for (CFIndex c = 0; c < cookieCount; ++c) {
            if (attributes[i].whole.location < cookies[c].location
                || attributes[i].whole.location >= cookies[c].location + cookies[c].length)
                continue;
            attributes[i].cookie = (long)c;
            break;
        }
    }

    // The comment the server sent this cookie, read from the cookie's own bytes.
    for (CFIndex c = 0; c < cookieCount; ++c) {
        CFStringRef one = CFStringCreateWithSubstring(NULL, header, cookies[c]);
        if (!one)
            wk_patch_fail(kSameSiteEncoding, "a cookie's bytes could not be read");
        CFArrayRef parsed = wk_parseSetCookieHeader(one, url);
        if (parsed && CFArrayGetCount(parsed) == 1)
            originalComments[c] = WK_SYSTEM(CFHTTPCookieCopyComment)((WKHTTPCookieRef)CFArrayGetValueAtIndex(parsed, 0));
        if (parsed)
            CFRelease(parsed);
        CFRelease(one);
    }

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
        *rewritten = result;
        disposition = WK_SAMESITE_HEADER_REWRITTEN;
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
    free(edits);
    free(blobs);
    free(commentFields);
    free(originalComments);
    free(firstOwned);
    free(lastSameSite);
    free(attributes);
    free(cookies);
    return disposition;
}

// Everything a Set-Cookie field is held to before a storage takes it in, in the order the passes edit:
// the control-character rule, then the cookies that may not be set at all, then the lifetime ceiling,
// then the SameSite attribute, whose rewrite must land on the ranges the others left behind. Answers a
// new field when any pass changed it, NULL when the field is already storable as it stands, and sets
// *outSetsNothing for a field whose every cookie was refused -- which its caller must not pass on.
//
// One function rather than one per caller: the two seams a response's cookies arrive through -- the
// storage's own setCookiesWithResponseHeaderFields (c/CFNetwork.c) and
// +[NSHTTPCookie cookiesWithResponseHeaderFields:forURL:] (methods/Foundation.m), which is also what
// the WebSocket handshake and document.cookie reach -- must hold a field to the same rules.
CFStringRef wk_storableSetCookieFieldCreate(CFStringRef header, CFURLRef url, bool *outSetsNothing)
{
    *outSetsNothing = false;
    if (!header || !CFStringGetLength(header) || !url)
        return NULL;

    CFStringRef current = (CFStringRef)CFRetain(header);
    bool changed = false;

    if (wk_hasControlCharacter(current)) {
        CFStringRef withoutControls = wk_copyFieldWithoutControlCookies(current);
        CFRelease(current);
        if (!withoutControls) {
            // Every set-cookie-string in the field is ignored, so the field sets nothing.
            *outSetsNothing = true;
            return NULL;
        }
        current = withoutControls;
        changed = true;
    }

    CFStringRef canonical = wk_cookieFieldWithLastAttributeWinningCreate(current);
    if (canonical) {
        CFRelease(current);
        current = canonical;
        changed = true;
    }

    bool setsNothing = false;
    CFStringRef allowed = wk_cookieFieldWithoutRefusedCookiesCreate(current, url, &setsNothing);
    if (allowed) {
        CFRelease(current);
        if (setsNothing) {
            CFRelease(allowed);
            *outSetsNothing = true;
            return NULL;
        }
        current = allowed;
        changed = true;
    }

    CFStringRef capped = wk_cookieLifetimeCappedHeaderCreate(current, url);
    if (capped) {
        CFRelease(current);
        current = capped;
        changed = true;
    }

    CFStringRef rewritten = NULL;
    if (wk_sameSiteRewriteSetCookieHeader(current, url, &rewritten) == WK_SAMESITE_HEADER_REWRITTEN) {
        CFRelease(current);
        current = rewritten;
        changed = true;
    }

    if (changed)
        return current;
    CFRelease(current);
    return NULL;
}
