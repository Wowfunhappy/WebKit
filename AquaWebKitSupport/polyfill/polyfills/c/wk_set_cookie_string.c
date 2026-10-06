// See wk_set_cookie_string.h.
#include "wk_set_cookie_string.h"

#include <stdbool.h>
#include <stdlib.h>

typedef enum { WKSegmentName, WKSegmentValue, WKSegmentAttributeName, WKSegmentAttributeValue } WKSegment;

// The date after an expires attribute: its leading word, the spaces after that word, and everything past them.
typedef enum { WKExpiresBeforeWord, WKExpiresInWord, WKExpiresAfterWord, WKExpiresPastComma } WKExpiresState;

static bool wk_isAttributeNamed(const UniChar *characters, CFIndex start, CFIndex end, const char *name)
{
    while (start < end && characters[start] == ' ')
        ++start;
    while (end > start && characters[end - 1] == ' ')
        --end;
    CFIndex index = 0;
    for (; start < end; ++start, ++index) {
        UniChar character = characters[start];
        if (character >= 'A' && character <= 'Z')
            character += 'a' - 'A';
        if (!name[index] || character != (UniChar)name[index])
            return false;
    }
    return !name[index];
}

static bool wk_isCookiePiece(const UniChar *characters, CFIndex nameStart, CFIndex nameEnd, bool hasValue)
{
    if (!hasValue || nameStart < 0)
        return false;
    while (nameEnd > nameStart && characters[nameEnd - 1] == ' ')
        --nameEnd;
    if (nameEnd <= nameStart || characters[nameStart] == '"')
        return false;
    for (CFIndex i = nameStart; i < nameEnd; ++i) {
        if (characters[i] == '\t')
            return false;
    }
    return true;
}

CFRange wk_setCookieStringFirstCookieRange(CFStringRef string)
{
    CFRange none = CFRangeMake(kCFNotFound, 0);
    CFIndex length = string ? CFStringGetLength(string) : 0;
    if (!length)
        return none;
    UniChar *characters = malloc(sizeof(UniChar) * (size_t)length);
    if (!characters)
        abort();
    CFStringGetCharacters(string, CFRangeMake(0, length), characters);

    CFRange result = none;
    for (CFIndex i = 0; i < length; ++i) {
        if (characters[i] == '\r' || characters[i] == '\n')
            goto done;
    }

    for (CFIndex i = 0; i < length && result.location == kCFNotFound; ) {
        WKSegment segment = WKSegmentName;
        CFIndex tokenCharacters = 0;
        CFIndex nameStart = -1;
        CFIndex nameEnd = -1;
        bool hasValue = false;
        CFIndex attributeNameStart = i;
        bool inExpires = false;
        WKExpiresState expires = WKExpiresBeforeWord;
        CFIndex pieceEnd = length;

        while (i < length) {
            UniChar character = characters[i];
            bool inExpiresValue = segment == WKSegmentAttributeValue && inExpires;
            if (character == '"' && !tokenCharacters) {
                CFIndex close = i + 1;
                while (close < length && characters[close] != '"')
                    ++close;
                if (close < length) {
                    if (segment == WKSegmentName && nameStart < 0)
                        nameStart = i;
                    ++tokenCharacters;
                    if (inExpiresValue)
                        expires = WKExpiresPastComma;
                    i = close + 1;
                    continue;
                }
            }
            if (character == ',') {
                UniChar next = i + 1 < length ? characters[i + 1] : 0;
                if (next == ' ' || next == '\t') {
                    if (inExpiresValue && (expires == WKExpiresInWord || expires == WKExpiresAfterWord)) {
                        expires = WKExpiresPastComma;
                        ++tokenCharacters;
                        ++i;
                        continue;
                    }
                    pieceEnd = i;
                    ++i;
                    break;
                }
                if (!tokenCharacters) {
                    ++i;
                    continue;
                }
                if (segment == WKSegmentName && nameStart < 0)
                    nameStart = i;
                tokenCharacters += next ? 2 : 1;
                if (inExpiresValue)
                    expires = WKExpiresPastComma;
                i += next ? 2 : 1;
                continue;
            }
            if (character == ';') {
                if (segment == WKSegmentName)
                    nameEnd = i;
                segment = WKSegmentAttributeName;
                tokenCharacters = 0;
                attributeNameStart = i + 1;
                inExpires = false;
                ++i;
                continue;
            }
            if (character == '=' && (segment == WKSegmentName || segment == WKSegmentAttributeName)) {
                if (segment == WKSegmentName) {
                    nameEnd = i;
                    hasValue = true;
                    segment = WKSegmentValue;
                } else {
                    inExpires = wk_isAttributeNamed(characters, attributeNameStart, i, "expires");
                    expires = WKExpiresBeforeWord;
                    segment = WKSegmentAttributeValue;
                }
                tokenCharacters = 0;
                ++i;
                continue;
            }
            if (character == ' ') {
                if (inExpiresValue && expires == WKExpiresInWord)
                    expires = WKExpiresAfterWord;
                ++i;
                continue;
            }
            if (segment == WKSegmentName && nameStart < 0)
                nameStart = i;
            ++tokenCharacters;
            if (inExpiresValue) {
                if (character == '"' || expires == WKExpiresAfterWord)
                    expires = WKExpiresPastComma;
                else if (expires == WKExpiresBeforeWord)
                    expires = WKExpiresInWord;
            }
            ++i;
        }
        if (segment == WKSegmentName)
            nameEnd = pieceEnd;
        if (wk_isCookiePiece(characters, nameStart, nameEnd, hasValue))
            result = CFRangeMake(nameStart, pieceEnd - nameStart);
    }

done:
    free(characters);
    return result;
}
