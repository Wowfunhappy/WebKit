// CTTypesetterCreateWithUniCharProviderAndOptions, CTLineCreateWithUniCharProvider and CTRunGetAttributes
// with morx subtables that run in logical order, and natural-direction text: right-to-left text forms the
// ligatures left-to-right text forms, a subtable without the flag runs as 10.9 runs it, natural direction
// resolves the levels current Unicode does, and every run reports the attributes its text was provided in. The logical-order font is 10.9's own Apple Color Emoji with the flag set on its
// subtables; when the installed Apple Color Emoji carries the flag itself, it is checked as well.

#define U_DISABLE_RENAMING 1
#include <unicode/ubidi.h>
#include <unicode/uchar.h>

#include <ApplicationServices/ApplicationServices.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef const UniChar *(*CTUniCharProviderCallback)(CFIndex, CFIndex *, CFDictionaryRef *, void *);
typedef void (*CTUniCharDisposeCallback)(const UniChar *, void *);
extern CTLineRef CTLineCreateWithUniCharProvider(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *);
extern CTTypesetterRef CTTypesetterCreateWithUniCharProviderAndOptions(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *, CFDictionaryRef);

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

enum { MaxBlocks = 8, MaxGlyphs = 64 };

typedef struct {
    const UniChar *characters;
    CFIndex length;
    CFIndex starts[MaxBlocks];
    CFDictionaryRef attributes[MaxBlocks];
    int blockCount;
    const UniChar *provided[64];
    int providedCount;
    int disposedCount;
    bool disposedUnprovided;
} Text;

static const UniChar *provide(CFIndex index, CFIndex *count, CFDictionaryRef *attributes, void *refCon)
{
    Text *text = (Text *)refCon;
    if (index < 0 || index >= text->length) {
        *count = 0;
        return NULL;
    }
    int block = 0;
    while (block + 1 < text->blockCount && text->starts[block + 1] <= index)
        ++block;
    CFIndex end = block + 1 < text->blockCount ? text->starts[block + 1] : text->length;
    *count = end - index;
    *attributes = text->attributes[block];
    if (text->providedCount < 64)
        text->provided[text->providedCount] = text->characters + index;
    ++text->providedCount;
    return text->characters + index;
}

static void dispose(const UniChar *characters, void *refCon)
{
    Text *text = (Text *)refCon;
    bool known = false;
    for (int i = 0; i < text->providedCount && i < 64; ++i)
        known = known || text->provided[i] == characters;
    text->disposedUnprovided = text->disposedUnprovided || !known;
    ++text->disposedCount;
}

typedef struct {
    CFIndex runCount;
    CFRange ranges[MaxGlyphs];
    CFDictionaryRef attributes[MaxGlyphs];
    CGGlyph glyphs[MaxGlyphs];
    CFIndex glyphCount;
    double width;
} Shape;

static void readLine(CTLineRef line, Shape *shape)
{
    memset(shape, 0, sizeof(*shape));
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    shape->runCount = CFArrayGetCount(runs);
    shape->width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    for (CFIndex r = 0; r < shape->runCount && r < MaxGlyphs; ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        shape->ranges[r] = CTRunGetStringRange(run);
        // Retained: a dictionary the line made itself goes with the line, which the callers release.
        shape->attributes[r] = (CFDictionaryRef)CFRetain(CTRunGetAttributes(run));
        CFIndex count = CTRunGetGlyphCount(run);
        if (shape->glyphCount + count <= MaxGlyphs) {
            CTRunGetGlyphs(run, CFRangeMake(0, count), shape->glyphs + shape->glyphCount);
            shape->glyphCount += count;
        }
    }
}

static CFDictionaryRef forcedLevel(short level)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberShortType, &level);
    CFTypeRef keys[] = { kCTTypesetterOptionForcedEmbeddingLevel };
    CFTypeRef values[] = { number };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    return options;
}

static void shapeForced(Text *text, short level, Shape *shape)
{
    CFDictionaryRef options = forcedLevel(level);
    CTTypesetterRef typesetter = CTTypesetterCreateWithUniCharProviderAndOptions(provide, NULL, text, options);
    CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
    readLine(line, shape);
    CFRelease(line);
    CFRelease(typesetter);
    CFRelease(options);
}

// The same text typeset from an attributed string, which reads no provider.
static void shapeNative(const UniChar *characters, CFIndex length, CTFontRef font, short level, Shape *shape)
{
    CFStringRef string = CFStringCreateWithCharacters(NULL, characters, length);
    CFTypeRef keys[] = { kCTFontAttributeName };
    CFTypeRef values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CFDictionaryRef options = forcedLevel(level);
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, options);
    CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
    readLine(line, shape);
    CFRelease(line);
    CFRelease(typesetter);
    CFRelease(options);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
}

static CFDictionaryRef attributesWithFont(CTFontRef font)
{
    CFTypeRef keys[] = { kCTFontAttributeName };
    CFTypeRef values[] = { font };
    return CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static bool sameGlyphs(const Shape *a, const CGGlyph *glyphs, CFIndex count)
{
    return a->glyphCount == count && !memcmp(a->glyphs, glyphs, (size_t)count * sizeof(CGGlyph));
}

// Whether reported, apart from its font, holds exactly what provided holds.
static bool equalApartFromFont(CFDictionaryRef reported, CFDictionaryRef provided)
{
    CFIndex count = CFDictionaryGetCount(reported);
    if (count != CFDictionaryGetCount(provided) || count > 32)
        return false;
    CFTypeRef keys[32];
    CFTypeRef values[32];
    CFDictionaryGetKeysAndValues(reported, keys, values);
    for (CFIndex i = 0; i < count; ++i) {
        if (CFEqual(keys[i], kCTFontAttributeName))
            continue;
        CFTypeRef value = CFDictionaryGetValue(provided, keys[i]);
        if (!value || !CFEqual(value, values[i]))
            return false;
    }
    return true;
}

// Every run reports a dictionary the provider handed out, or, for a run CoreText set in a fallback font, the
// provided attributes with that font; never a shaping instance or anything added to set levels.
static bool reportsProvidedAttributes(const Shape *shape, const Text *text)
{
    for (CFIndex r = 0; r < shape->runCount; ++r) {
        CFDictionaryRef reported = shape->attributes[r];
        if (CFDictionaryGetValue(reported, CFSTR("WKSourceAttributes")) || CFDictionaryGetValue(reported, kCTWritingDirectionAttributeName))
            return false;
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(reported, kCTFontAttributeName);
        CFTypeRef url = font ? CTFontCopyAttribute(font, kCTFontURLAttribute) : NULL;
        bool providedFont = false;
        bool provided = false;
        for (int b = 0; b < text->blockCount; ++b) {
            providedFont = providedFont || font == CFDictionaryGetValue(text->attributes[b], kCTFontAttributeName);
            provided = provided || reported == text->attributes[b] || equalApartFromFont(reported, text->attributes[b]);
        }
        if (url)
            CFRelease(url);
        if (!provided || !(url || providedFont))
            return false;
    }
    return true;
}

static bool rangesTile(const Shape *shape, CFIndex length)
{
    CFIndex covered = 0;
    for (CFIndex r = 0; r < shape->runCount; ++r)
        covered += shape->ranges[r].length;
    return covered == length;
}

static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

// Sets or reads the logical-order flag on every morx subtable of an sfnt held in memory.
static bool logicalOrderFlags(uint8_t *font, bool set)
{
    bool found = false;
    uint16_t tableCount = (uint16_t)((font[4] << 8) | font[5]);
    for (uint16_t t = 0; t < tableCount; ++t) {
        const uint8_t *entry = font + 12 + 16 * t;
        if (memcmp(entry, "morx", 4))
            continue;
        uint8_t *morx = font + be32(entry + 8);
        uint32_t chains = be32(morx + 4), chain = 8;
        for (uint32_t c = 0; c < chains; ++c) {
            uint32_t chainLength = be32(morx + chain + 4), features = be32(morx + chain + 8), subtables = be32(morx + chain + 12);
            uint32_t subtable = chain + 16 + 12 * features;
            for (uint32_t s = 0; s < subtables; ++s) {
                found = found || (morx[subtable + 4] & 0x10);
                if (set)
                    morx[subtable + 4] |= 0x10;
                subtable += be32(morx + subtable);
            }
            chain += chainLength;
        }
    }
    return found;
}

static bool fontHasLogicalOrderSubtables(CTFontRef font)
{
    CFDataRef morx = CTFontCopyTable(font, 'morx', kCTFontTableOptionNoOptions);
    bool found = false;
    if (morx && CFDataGetLength(morx) >= 8) {
        const uint8_t *m = CFDataGetBytePtr(morx);
        uint64_t length = (uint64_t)CFDataGetLength(morx);
        uint64_t chain = 8;
        for (uint32_t c = 0, chains = be32(m + 4); c < chains && chain + 16 <= length; ++c) {
            uint64_t chainEnd = chain + be32(m + chain + 4);
            uint64_t subtable = chain + 16 + 12 * (uint64_t)be32(m + chain + 8);
            if (chainEnd <= chain || chainEnd > length)
                break;
            for (uint32_t s = 0, subtables = be32(m + chain + 12); s < subtables && subtable + 12 <= chainEnd; ++s) {
                uint32_t subtableLength = be32(m + subtable);
                found = found || (m[subtable + 4] & 0x10);
                if (subtableLength < 12)
                    break;
                subtable += subtableLength;
            }
            chain = chainEnd;
        }
    }
    if (morx)
        CFRelease(morx);
    return found;
}

static double internalMegabytes(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.internal / 1048576.0;
}

// Visual order and run directions of a line against the levels this port's ICU resolves.
static bool matchesCurrentLevels(CTLineRef line, const UniChar *characters, CFIndex length, UBiDiLevel paragraphLevel)
{
    UErrorCode status = U_ZERO_ERROR;
    UBiDi *bidi = ubidi_open();
    ubidi_setPara(bidi, characters, (int32_t)length, paragraphLevel, NULL, &status);
    int32_t expected[64];
    ubidi_getVisualMap(bidi, expected, &status);
    const UBiDiLevel *levels = ubidi_getLevels(bidi, &status);
    bool same = U_SUCCESS(status) && length <= 64;
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex visual = 0;
    for (CFIndex r = 0; same && r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFRange range = CTRunGetStringRange(run);
        bool rightToLeft = CTRunGetStatus(run) & kCTRunStatusRightToLeft;
        for (CFIndex i = 0; same && i < range.length; ++i, ++visual) {
            CFIndex index = rightToLeft ? range.location + range.length - 1 - i : range.location + i;
            same = visual < length && expected[visual] == index && ((levels[index] & 1) != 0) == rightToLeft;
        }
    }
    ubidi_close(bidi);
    return same && visual == length;
}

// A line whose blocks carry their own paragraph styles: each paragraph resolves at the level its starting block's
// style gives it, and the line is reordered as one line.
static bool matchesParagraphLevels(CTLineRef line, const UniChar *characters, CFIndex length, const CFIndex *paragraphStarts,
    const UBiDiLevel *paragraphLevels, int paragraphCount)
{
    UBiDiLevel levels[64];
    int32_t expected[64];
    if (length > 64)
        return false;
    for (int p = 0; p < paragraphCount; ++p) {
        CFIndex start = paragraphStarts[p];
        CFIndex end = p + 1 < paragraphCount ? paragraphStarts[p + 1] : length;
        UErrorCode status = U_ZERO_ERROR;
        UBiDi *bidi = ubidi_open();
        ubidi_setPara(bidi, characters + start, (int32_t)(end - start), paragraphLevels[p], NULL, &status);
        const UBiDiLevel *paragraph = ubidi_getLevels(bidi, &status);
        if (U_FAILURE(status)) {
            ubidi_close(bidi);
            return false;
        }
        memcpy(levels + start, paragraph, (size_t)(end - start));
        ubidi_close(bidi);
    }
    ubidi_reorderVisual(levels, (int32_t)length, expected);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex visual = 0;
    bool same = true;
    for (CFIndex r = 0; same && r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFRange range = CTRunGetStringRange(run);
        bool rightToLeft = CTRunGetStatus(run) & kCTRunStatusRightToLeft;
        for (CFIndex i = 0; same && i < range.length; ++i, ++visual) {
            CFIndex index = rightToLeft ? range.location + range.length - 1 - i : range.location + i;
            same = visual < length && expected[visual] == index && ((levels[index] & 1) != 0) == rightToLeft;
        }
    }
    return same && visual == length;
}

static void put16(uint8_t *bytes, uint16_t value)
{
    bytes[0] = (uint8_t)(value >> 8);
    bytes[1] = (uint8_t)value;
}

static void put32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

static int compareTags(const void *a, const void *b)
{
    uint32_t first = *(const uint32_t *)a, second = *(const uint32_t *)b;
    return first < second ? -1 : first > second;
}

// A font's tables as an sfnt, with a format 4 cmap covering its BMP characters except those left out: the shape of a
// web font subset without them.
static CFDataRef createFontWithout(CTFontRef font, const UniChar *leftOut, int leftOutCount)
{
    uint16_t *glyphs = (uint16_t *)calloc(0x10000, sizeof(uint16_t));
    for (uint32_t c = 0; c < 0xFFFF; ++c) {
        bool omitted = c >= 0xD800 && c <= 0xDFFF;
        for (int i = 0; i < leftOutCount; ++i)
            omitted = omitted || c == leftOut[i];
        if (omitted)
            continue;
        UniChar character = (UniChar)c;
        CGGlyph glyph;
        if (CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
            glyphs[c] = glyph;
    }
    uint32_t *segmentStart = (uint32_t *)malloc(0x10000 * sizeof(uint32_t)), *segmentEnd = (uint32_t *)malloc(0x10000 * sizeof(uint32_t));
    uint16_t segments = 0;
    uint32_t mapped = 0;
    for (uint32_t c = 0; c < 0xFFFF; ++c) {
        if (!glyphs[c])
            continue;
        uint32_t end = c;
        while (end + 1 < 0xFFFF && glyphs[end + 1])
            ++end;
        segmentStart[segments] = c;
        segmentEnd[segments++] = end;
        mapped += end - c + 1;
        c = end;
    }
    segmentStart[segments] = segmentEnd[segments] = 0xFFFF;
    ++segments;
    size_t subtableLength = 16 + 8 * (size_t)segments + 2 * (size_t)mapped;
    CFMutableDataRef cmap = CFDataCreateMutable(NULL, 0);
    CFDataSetLength(cmap, (CFIndex)(12 + subtableLength));
    uint8_t *table = CFDataGetMutableBytePtr(cmap);
    put16(table + 2, 1);
    put16(table + 4, 3);
    put16(table + 6, 1);
    put32(table + 8, 12);
    uint8_t *subtable = table + 12;
    put16(subtable, 4);
    put16(subtable + 2, (uint16_t)subtableLength);
    put16(subtable + 6, (uint16_t)(2 * segments));
    uint16_t selector = 0;
    while ((2u << selector) <= segments)
        ++selector;
    put16(subtable + 8, (uint16_t)(2u << selector));
    put16(subtable + 10, selector);
    put16(subtable + 12, (uint16_t)(2 * segments - (2u << selector)));
    uint8_t *ends = subtable + 14, *starts = subtable + 16 + 2 * segments, *deltas = starts + 2 * segments, *offsets = deltas + 2 * segments, *array = offsets + 2 * segments;
    uint32_t cursor = 0;
    for (uint16_t i = 0; i < segments; ++i) {
        put16(ends + 2 * i, (uint16_t)segmentEnd[i]);
        put16(starts + 2 * i, (uint16_t)segmentStart[i]);
        if (segmentStart[i] == 0xFFFF) {
            put16(deltas + 2 * i, 1);
            continue;
        }
        put16(offsets + 2 * i, (uint16_t)((array + 2 * cursor) - (offsets + 2 * i)));
        for (uint32_t c = segmentStart[i]; c <= segmentEnd[i]; ++c)
            put16(array + 2 * cursor++, glyphs[c]);
    }
    free(glyphs);
    free(segmentStart);
    free(segmentEnd);

    CFArrayRef tagArray = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    CFIndex tagCount = CFArrayGetCount(tagArray);
    uint32_t tags[64];
    CFDataRef tables[64];
    int count = 0;
    size_t tablesLength = 0;
    for (CFIndex i = 0; i < tagCount && i < 64; ++i)
        tags[i] = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tagArray, i);
    qsort(tags, (size_t)(tagCount < 64 ? tagCount : 64), sizeof(uint32_t), compareTags);
    for (CFIndex i = 0; i < tagCount && i < 64; ++i) {
        CFDataRef data = tags[i] == 'cmap' ? (CFDataRef)CFRetain(cmap) : CTFontCopyTable(font, tags[i], kCTFontTableOptionNoOptions);
        if (!data)
            continue;
        tags[count] = tags[i];
        tables[count++] = data;
        tablesLength += (CFDataGetLength(data) + 3) & ~(CFIndex)3;
    }
    CFRelease(tagArray);
    CFRelease(cmap);
    size_t directoryLength = 12 + 16 * (size_t)count;
    CFMutableDataRef sfnt = CFDataCreateMutable(NULL, 0);
    CFDataSetLength(sfnt, (CFIndex)(directoryLength + tablesLength));
    uint8_t *bytes = CFDataGetMutableBytePtr(sfnt);
    put32(bytes, 0x00010000);
    put16(bytes + 4, (uint16_t)count);
    size_t offset = directoryLength;
    for (int i = 0; i < count; ++i) {
        size_t length = (size_t)CFDataGetLength(tables[i]);
        memcpy(bytes + offset, CFDataGetBytePtr(tables[i]), length);
        uint8_t *entry = bytes + 12 + 16 * i;
        put32(entry, tags[i]);
        put32(entry + 8, (uint32_t)offset);
        put32(entry + 12, (uint32_t)length);
        offset += (length + 3) & ~(size_t)3;
        CFRelease(tables[i]);
    }
    return sfnt;
}

// Every run's first glyph is the glyph the font it reports has for that run's first character. An isolate control
// has no glyph of its own in any font here, so where one is laid out it is invisible in the reported font: a
// glyph with no advance that is deleted or has no outline.
static bool runsReportTheirGlyphsFonts(CTLineRef line, const UniChar *characters)
{
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex count = CTRunGetGlyphCount(run);
        if (!count)
            continue;
        CGGlyph glyph;
        CFIndex index;
        CGSize advance;
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph);
        CTRunGetStringIndices(run, CFRangeMake(0, 1), &index);
        CTRunGetAdvances(run, CFRangeMake(0, 1), &advance);
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        if (!font)
            return false;
        UniChar character = characters[index];
        if (character >= 0x2066 && character <= 0x2069) {
            if (advance.width != 0)
                return false;
            if (glyph != 0xFFFF) {
                CGPathRef outline = CTFontCreatePathForGlyph(font, glyph, NULL);
                bool empty = !outline || CGPathIsEmpty(outline);
                if (outline)
                    CGPathRelease(outline);
                if (!empty)
                    return false;
            }
            continue;
        }
        CGGlyph reported = 0;
        if (!CTFontGetGlyphsForCharacters(font, &character, &reported, 1) || reported != glyph)
            return false;
    }
    return true;
}

static bool hasNotdef(CTLineRef line)
{
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex count = CTRunGetGlyphCount(run);
        CGGlyph glyphs[64];
        CTRunGetGlyphs(run, CFRangeMake(0, count < 64 ? count : 64), glyphs);
        for (CFIndex i = 0; i < count && i < 64; ++i) {
            if (!glyphs[i])
                return true;
        }
    }
    return false;
}

static CFDictionaryRef attributesWithParagraphDirection(CTFontRef font, CTWritingDirection direction)
{
    CTParagraphStyleSetting setting = { kCTParagraphStyleSpecifierBaseWritingDirection, sizeof(direction), &direction };
    CTParagraphStyleRef style = CTParagraphStyleCreate(&setting, 1);
    CFTypeRef keys[] = { kCTFontAttributeName, kCTParagraphStyleAttributeName };
    CFTypeRef values[] = { font, style };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(style);
    return attributes;
}

// Lays text out in natural direction, as a line and as a typesetter with no forced level, and checks its
// levels, its runs' attributes and its disposal.
static void checkNaturalDirection(const char *name, const UniChar *characters, CFIndex length, CFDictionaryRef attributes, UBiDiLevel paragraphLevel)
{
    char what[256];
    Text text = { characters, length, { 0 }, { attributes }, 1, { 0 }, 0, 0, false };
    CTLineRef line = CTLineCreateWithUniCharProvider(provide, dispose, &text);
    Shape shape;
    readLine(line, &shape);
    snprintf(what, sizeof(what), "%s, line: the levels current Unicode resolves", name);
    check(matchesCurrentLevels(line, characters, length, paragraphLevel), what);
    snprintf(what, sizeof(what), "%s, line: runs report the provided attributes", name);
    check(reportsProvidedAttributes(&shape, &text), what);
    int provided = text.providedCount;
    CFRelease(line);
    snprintf(what, sizeof(what), "%s, line: each block handed out is disposed of once", name);
    check(text.disposedCount == provided && !text.disposedUnprovided, what);

    CFDictionaryRef noOptions = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    text = (Text) { characters, length, { 0 }, { attributes }, 1, { 0 }, 0, 0, false };
    CTTypesetterRef typesetter = CTTypesetterCreateWithUniCharProviderAndOptions(provide, dispose, &text, noOptions);
    line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
    snprintf(what, sizeof(what), "%s, typesetter with no forced level: the levels current Unicode resolves", name);
    check(matchesCurrentLevels(line, characters, length, paragraphLevel), what);
    CFRelease(line);
    provided = text.providedCount;
    CFRelease(typesetter);
    snprintf(what, sizeof(what), "%s, typesetter with no forced level: each block handed out is disposed of once", name);
    check(text.disposedCount == provided && !text.disposedUnprovided, what);
    CFRelease(noOptions);
}

// What the provider layer's skip of the second resolution rests on, checked against both ICUs on this OS:
// below U+058D every code point has one class in both and the paired brackets are ASCII's, below U+0590
// none raises a level, and the emoji modifiers are classed differently.
static void checkBidiDataPremises(void)
{
    void *icucore = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    UCharDirection (*systemDirection)(UChar32) = icucore ? dlsym(icucore, "u_charDirection") : NULL;
    check(systemDirection && systemDirection != u_charDirection, "libicucore's u_charDirection is its own");
    if (!systemDirection)
        return;
    bool sameBelowArmenianSigns = true, noneRaise = true, bracketsAreAscii = true;
    for (UChar32 codePoint = 0; codePoint < 0x0590; ++codePoint) {
        UCharDirection current = u_charDirection(codePoint);
        if (codePoint < 0x058D)
            sameBelowArmenianSigns = sameBelowArmenianSigns && current == systemDirection(codePoint);
        noneRaise = noneRaise && current != U_RIGHT_TO_LEFT && current != U_RIGHT_TO_LEFT_ARABIC && current != U_ARABIC_NUMBER
            && current != U_LEFT_TO_RIGHT_EMBEDDING && current != U_LEFT_TO_RIGHT_OVERRIDE && current != U_RIGHT_TO_LEFT_EMBEDDING
            && current != U_RIGHT_TO_LEFT_OVERRIDE && current != U_POP_DIRECTIONAL_FORMAT;
        bool ascii = codePoint == '(' || codePoint == ')' || codePoint == '[' || codePoint == ']' || codePoint == '{' || codePoint == '}';
        if (codePoint < 0x058D)
            bracketsAreAscii = bracketsAreAscii && ((u_getIntPropertyValue(codePoint, UCHAR_BIDI_PAIRED_BRACKET_TYPE) != U_BPT_NONE) == ascii);
    }
    check(sameBelowArmenianSigns, "below U+058D, ICU 51 and ICU 74 class every code point alike");
    check(systemDirection(0x058D) != u_charDirection(0x058D) && systemDirection(0x058E) != u_charDirection(0x058E), "U+058D and U+058E are classed differently");
    check(noneRaise, "below U+0590, no class raises a level");
    bool separatorsAsListed = true;
    for (UChar32 codePoint = 0; codePoint < 0x058D; ++codePoint) {
        bool listed = codePoint == '\n' || codePoint == '\r' || (codePoint >= 0x1C && codePoint <= 0x1E) || codePoint == 0x85;
        separatorsAsListed = separatorsAsListed && ((u_charDirection(codePoint) == U_BLOCK_SEPARATOR) == listed);
    }
    check(separatorsAsListed, "below U+058D, the paragraph separators are LF, CR, U+001C-001E and U+0085");
    check(bracketsAreAscii, "below U+058D, the paired brackets are the six ASCII ones");
    check(systemDirection(0x1F3FE) == U_LEFT_TO_RIGHT && u_charDirection(0x1F3FE) == U_OTHER_NEUTRAL, "an emoji modifier is left to right in ICU 51 and a neutral in ICU 74");
}

#define UNITS(...) (const UniChar[]){ __VA_ARGS__ }, (CFIndex)(sizeof((UniChar[]){ __VA_ARGS__ }) / sizeof(UniChar))

int main(void)
{
    const char *path = "/System/Library/Fonts/Apple Color Emoji.ttf";
    int fd = open(path, O_RDONLY);
    struct stat status;
    if (fd < 0 || fstat(fd, &status)) {
        fprintf(stderr, "FAIL cannot open %s\n", path);
        return 1;
    }
    uint8_t *layoutBytes = mmap(NULL, (size_t)status.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    uint8_t *logicalBytes = mmap(NULL, (size_t)status.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    close(fd);
    check(!logicalOrderFlags(layoutBytes, false), "10.9's Apple Color Emoji has no logical-order subtable");
    logicalOrderFlags(logicalBytes, true);
    CGDataProviderRef layoutProvider = CGDataProviderCreateWithData(NULL, layoutBytes, (size_t)status.st_size, NULL);
    CGDataProviderRef logicalProvider = CGDataProviderCreateWithData(NULL, logicalBytes, (size_t)status.st_size, NULL);
    CGFontRef layoutGraphics = CGFontCreateWithDataProvider(layoutProvider);
    CGFontRef logicalGraphics = CGFontCreateWithDataProvider(logicalProvider);
    CTFontRef layoutFont = CTFontCreateWithGraphicsFont(layoutGraphics, 16, NULL, NULL);
    CTFontRef logicalFont = CTFontCreateWithGraphicsFont(logicalGraphics, 16, NULL, NULL);
    CTFontRef lucida = CTFontCreateWithName(CFSTR("LucidaGrande"), 16, NULL);
    CFDictionaryRef logical = attributesWithFont(logicalFont);
    CFDictionaryRef layout = attributesWithFont(layoutFont);
    CFDictionaryRef hebrew = attributesWithFont(lucida);

    const UniChar flagUnits[] = { 0xD83C, 0xDDFA, 0xD83C, 0xDDF8 };
    const UniChar keycapUnits[] = { '1', 0xFE0F, 0x20E3 };
    Shape ltr, rtl, native;

    // A flag and a keycap each ligate right to left as they do left to right.
    Text text = { flagUnits, 4, { 0 }, { logical }, 1, { 0 }, 0, 0, false };
    shapeForced(&text, 0, &ltr);
    shapeForced(&text, 1, &rtl);
    check(ltr.glyphCount == 1, "flag, left to right: one glyph");
    check(sameGlyphs(&rtl, ltr.glyphs, ltr.glyphCount) && rtl.width == ltr.width, "flag, right to left: the left-to-right ligature");
    check(reportsProvidedAttributes(&rtl, &text), "flag, right to left: runs report the provided attributes");

    text = (Text) { keycapUnits, 3, { 0 }, { logical }, 1, { 0 }, 0, 0, false };
    shapeForced(&text, 0, &ltr);
    shapeForced(&text, 1, &rtl);
    check(ltr.glyphCount == 1, "keycap, left to right: one glyph");
    check(sameGlyphs(&rtl, ltr.glyphs, ltr.glyphCount), "keycap, right to left: the left-to-right ligature");

    // Left to right, and without the flag, the typesetter is CoreText's own.
    const UniChar pair[] = { 0xD83C, 0xDDFA, 0xD83C, 0xDDF8, '1', 0xFE0F, 0x20E3 };
    text = (Text) { pair, 7, { 0 }, { logical }, 1, { 0 }, 0, 0, false };
    shapeForced(&text, 0, &ltr);
    shapeNative(pair, 7, logicalFont, 0, &native);
    check(sameGlyphs(&ltr, native.glyphs, native.glyphCount), "left to right: the attributed-string typesetting");
    shapeForced(&text, 1, &rtl);
    CGGlyph reversed[MaxGlyphs];
    for (CFIndex i = 0; i < ltr.glyphCount; ++i)
        reversed[i] = ltr.glyphs[ltr.glyphCount - 1 - i];
    check(rtl.glyphCount == 2 && sameGlyphs(&rtl, reversed, ltr.glyphCount), "flag then keycap, right to left: both ligatures, in right-to-left order");

    text = (Text) { flagUnits, 4, { 0 }, { layout }, 1, { 0 }, 0, 0, false };
    shapeForced(&text, 1, &rtl);
    shapeNative(flagUnits, 4, layoutFont, 1, &native);
    check(sameGlyphs(&rtl, native.glyphs, native.glyphCount), "layout-order subtables, right to left: as 10.9 runs them");

    // Between Hebrew letters, forced right to left.
    const UniChar mixed[] = { 0x05D0, 0xD83C, 0xDDFA, 0xD83C, 0xDDF8, '1', 0xFE0F, 0x20E3, 0x05D1 };
    text = (Text) { mixed, 9, { 0, 1, 8 }, { hebrew, logical, hebrew }, 3, { 0 }, 0, 0, false };
    shapeForced(&text, 1, &rtl);
    shapeNative(mixed + 1, 7, logicalFont, 0, &ltr);
    bool emojiLigated = false;
    for (CFIndex i = 0; i + 1 < rtl.glyphCount; ++i)
        emojiLigated = emojiLigated || (rtl.glyphs[i] == ltr.glyphs[1] && rtl.glyphs[i + 1] == ltr.glyphs[0]);
    check(emojiLigated && rtl.glyphCount == 4, "Hebrew around flag and keycap, right to left: two ligatures between the letters");
    check(rangesTile(&rtl, 9) && reportsProvidedAttributes(&rtl, &text), "Hebrew around flag and keycap: runs tile the text and report the provided attributes");

    // Natural direction: the emoji resolve right to left between Hebrew letters.
    const UniChar natural[] = { 0x05D0, 0xD83C, 0xDDFA, 0xD83C, 0xDDF8, 0x05D1 };
    text = (Text) { natural, 6, { 0, 1, 5 }, { hebrew, logical, hebrew }, 3, { 0 }, 0, 0, false };
    CTLineRef line = CTLineCreateWithUniCharProvider(provide, dispose, &text);
    readLine(line, &rtl);
    shapeNative(flagUnits, 4, logicalFont, 0, &ltr);
    bool naturalLigated = false;
    for (CFIndex i = 0; i < rtl.glyphCount; ++i)
        naturalLigated = naturalLigated || rtl.glyphs[i] == ltr.glyphs[0];
    check(naturalLigated && rtl.glyphCount == 3, "natural direction, flag between Hebrew letters: the ligature");
    check(rangesTile(&rtl, 6) && reportsProvidedAttributes(&rtl, &text), "natural direction: runs tile the text and report the provided attributes");
    int providedBeforeRelease = text.providedCount;
    CFRelease(line);
    check(text.disposedCount == providedBeforeRelease - text.providedCount + providedBeforeRelease && !text.disposedUnprovided,
        "natural direction: each block the provider handed out is disposed of once");

    const UniChar naturalLatin[] = { 'a', 0xD83C, 0xDDFA, 0xD83C, 0xDDF8, 'b' };
    CTFontRef times = CTFontCreateWithName(CFSTR("Times-Roman"), 16, NULL);
    CFDictionaryRef latin = attributesWithFont(times);
    text = (Text) { naturalLatin, 6, { 0, 1, 5 }, { latin, logical, latin }, 3, { 0 }, 0, 0, false };
    line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    readLine(line, &rtl);
    CFRelease(line);
    check(rtl.glyphCount == 3 && rtl.glyphs[1] == ltr.glyphs[0], "natural direction, left-to-right paragraph: the ligature");

    // Natural direction resolves the levels current Unicode does: an emoji modifier is a neutral, a bracket
    // pair takes its enclosing direction, and a right-to-left paragraph style sets the paragraph level.
    const UniChar modifierBetweenHebrew[] = { 0x05D0, 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, 0x05D1 };
    const UniChar bracketPair[] = { 0x05D0, ' ', '(', 'b', ')', ' ', 'c' };
    const UniChar arabicDigits[] = { 0x0628, ' ', '1', '2', '3', ' ', 0x0633 };
    const UniChar latinBrackets[] = { 'a', ' ', '(', 'b', ')', ' ', 'c' };
    const UniChar latinWithHebrew[] = { 'a', ' ', 0x05D0, ' ', 'b', ' ', 'c' };
    checkNaturalDirection("emoji modifier between Hebrew letters", modifierBetweenHebrew, 6, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("bracket pair after a Hebrew letter", bracketPair, 7, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("Arabic around digits", arabicDigits, 7, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("Latin with a Hebrew letter", latinWithHebrew, 7, hebrew, UBIDI_DEFAULT_LTR);
    CFDictionaryRef rightToLeftParagraph = attributesWithParagraphDirection(lucida, kCTWritingDirectionRightToLeft);
    checkNaturalDirection("Latin brackets in a right-to-left paragraph", latinBrackets, 7, rightToLeftParagraph, 1);
    CFRelease(rightToLeftParagraph);

    // Isolate controls sit where current Unicode's levels put them, at the start of the text, around a
    // left-to-right or first-strong isolate, and nested, and add no width.
    const UniChar isolate[] = { 0x05D1, 0x2066, 'a', 0x2069, 0x05D2 };
    const UniChar isolateAtStart[] = { 0x2066, 'a', 'b', 0x2069, 0x05D1 };
    const UniChar firstStrongIsolate[] = { 0x05D1, 0x2068, 'a', 'b', 0x2069 };
    const UniChar nestedIsolates[] = { 0x05D1, 0x2067, 'a', 0x2066, 'b', 0x2069, 0x2069, 'c' };
    checkNaturalDirection("left-to-right isolate between Hebrew letters", isolate, 5, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("isolate at the start of the text", isolateAtStart, 5, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("first-strong isolate after a Hebrew letter", firstStrongIsolate, 5, hebrew, UBIDI_DEFAULT_LTR);
    checkNaturalDirection("nested isolates", nestedIsolates, 8, hebrew, UBIDI_DEFAULT_LTR);
    {
        const UniChar withoutControls[] = { 0x05D1, 'a', 0x05D2 };
        Text withText = { isolate, 5, { 0 }, { hebrew }, 1, { 0 }, 0, 0, false };
        Text withoutText = { withoutControls, 3, { 0 }, { hebrew }, 1, { 0 }, 0, 0, false };
        CTLineRef withLine = CTLineCreateWithUniCharProvider(provide, NULL, &withText);
        CTLineRef withoutLine = CTLineCreateWithUniCharProvider(provide, NULL, &withoutText);
        double widthWith = CTLineGetTypographicBounds(withLine, NULL, NULL, NULL);
        double widthWithout = CTLineGetTypographicBounds(withoutLine, NULL, NULL, NULL);
        check(widthWith > 0 && widthWith - widthWithout < 0.01 && widthWithout - widthWith < 0.01, "isolate controls add no width");
        CFRelease(withLine);
        CFRelease(withoutLine);
    }

    // Paragraphs: a right-to-left paragraph style and a left-to-right one on either side of U+2029, LF and CR LF,
    // the second holding an emoji modifier; a style that changes inside a paragraph, which the paragraph's start
    // decides; and natural paragraphs on either side of U+2029.
    {
        CFDictionaryRef rightToLeftStyle = attributesWithParagraphDirection(lucida, kCTWritingDirectionRightToLeft);
        CFDictionaryRef leftToRightStyle = attributesWithParagraphDirection(lucida, kCTWritingDirectionLeftToRight);
        const UniChar twoStyles[] = { 'a', ' ', 'b', 0x2029, 'c', ' ', 0x05D0, 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, 0x05D1, ' ', 'd' };
        const CFIndex twoStylesParagraphs[] = { 0, 4 };
        const UBiDiLevel twoStylesLevels[] = { 1, 0 };
        const UniChar styleChangesInside[] = { 'a', ' ', 'b', 0x2029, 'c', ' ', 'd' };
        const UBiDiLevel naturalThenRightToLeft[] = { UBIDI_DEFAULT_LTR, 1 };
        const UniChar lineFeed[] = { 'a', ' ', 'b', '\n', 'c', ' ', 0x05D0, 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, 0x05D1 };
        const UniChar carriageReturnLineFeed[] = { 'a', ' ', 'b', '\r', '\n', 'c', 0x05D0, 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, 0x05D1 };
        const CFIndex afterCarriageReturnLineFeed[] = { 0, 5 };
        const UniChar naturalParagraphs[] = { 0x05D0, ' ', 0x05D1, 0x2029, 'c', ' ', 'd' };
        const UBiDiLevel naturalLevels[] = { UBIDI_DEFAULT_LTR, UBIDI_DEFAULT_LTR };
        CFDictionaryRef noOptions = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        struct {
            const char *name;
            const UniChar *characters;
            CFIndex length;
            CFIndex split;
            CFDictionaryRef attributes[2];
            const CFIndex *paragraphStarts;
            const UBiDiLevel *paragraphLevels;
            int paragraphCount;
        } paragraphCases[] = {
            { "right-to-left and left-to-right paragraph styles", twoStyles, 14, 4, { rightToLeftStyle, leftToRightStyle }, twoStylesParagraphs, twoStylesLevels, 2 },
            { "a right-to-left style from inside a natural paragraph", styleChangesInside, 7, 2, { latin, rightToLeftStyle }, twoStylesParagraphs, naturalThenRightToLeft, 2 },
            { "right-to-left and left-to-right paragraph styles on either side of LF", lineFeed, 12, 4, { rightToLeftStyle, leftToRightStyle }, twoStylesParagraphs, twoStylesLevels, 2 },
            { "right-to-left and left-to-right paragraph styles on either side of CR LF", carriageReturnLineFeed, 12, 5, { rightToLeftStyle, leftToRightStyle }, afterCarriageReturnLineFeed, twoStylesLevels, 2 },
            { "natural paragraphs on either side of U+2029", naturalParagraphs, 7, 7, { hebrew, hebrew }, twoStylesParagraphs, naturalLevels, 2 },
        };
        for (size_t c = 0; c < sizeof(paragraphCases) / sizeof(*paragraphCases); ++c) {
            for (int route = 0; route < 2; ++route) {
                text = (Text) { paragraphCases[c].characters, paragraphCases[c].length, { 0, paragraphCases[c].split },
                    { paragraphCases[c].attributes[0], paragraphCases[c].attributes[1] }, paragraphCases[c].split < paragraphCases[c].length ? 2 : 1, { 0 }, 0, 0, false };
                CTTypesetterRef paragraphTypesetter = route ? CTTypesetterCreateWithUniCharProviderAndOptions(provide, NULL, &text, noOptions) : NULL;
                line = route ? CTTypesetterCreateLine(paragraphTypesetter, CFRangeMake(0, 0)) : CTLineCreateWithUniCharProvider(provide, NULL, &text);
                char what[256];
                snprintf(what, sizeof(what), "%s, %s: each paragraph at its own level", paragraphCases[c].name, route ? "typesetter with no forced level" : "line");
                check(matchesParagraphLevels(line, paragraphCases[c].characters, paragraphCases[c].length, paragraphCases[c].paragraphStarts,
                    paragraphCases[c].paragraphLevels, paragraphCases[c].paragraphCount), what);
                CFRelease(line);
                if (paragraphTypesetter)
                    CFRelease(paragraphTypesetter);
            }
        }
        CFRelease(noOptions);
        CFRelease(rightToLeftStyle);
        CFRelease(leftToRightStyle);
    }

    // A web font without U+034F, loaded through the sanitizer the way a downloadable font is, with CoreText's
    // cascade and with an empty cascade list: isolate controls add no width and no .notdef, and every run
    // reports the font its glyphs come from.
    {
        extern CFArrayRef FPFontCreateMemorySafeFontsFromData(CFDataRef);
        extern CTFontDescriptorRef CTFontManagerCreateMemorySafeFontDescriptorFromData(CFDataRef);
        CTFontRef arialHebrew = CTFontCreateWithName(CFSTR("ArialHebrew"), 24, NULL);
        // Without U+034F, and without U+034F and a space: a stand-in in a font without a space is U+FFFC.
        const UniChar withoutJoiner[] = { 0x034F };
        const UniChar withoutJoinerOrSpace[] = { 0x034F, ' ' };
        for (int subsetIndex = 0; subsetIndex < 2; ++subsetIndex) {
        CFDataRef subset = subsetIndex ? createFontWithout(arialHebrew, withoutJoinerOrSpace, 2) : createFontWithout(arialHebrew, withoutJoiner, 1);
        CFArrayRef sanitized = FPFontCreateMemorySafeFontsFromData(subset);
        CTFontDescriptorRef descriptor = sanitized && CFArrayGetCount(sanitized) ? CTFontManagerCreateMemorySafeFontDescriptorFromData((CFDataRef)CFArrayGetValueAtIndex(sanitized, 0)) : NULL;
        check(descriptor != NULL, "web font subset: the sanitizer accepts it");
        if (descriptor) {
            CTFontRef webFont = CTFontCreateWithFontDescriptor(descriptor, 24, NULL);
            UniChar joiner = 0x034F, alef = 0x05D0;
            CGGlyph glyph;
            UniChar space = ' ';
            check(!CTFontGetGlyphsForCharacters(webFont, &joiner, &glyph, 1) && CTFontGetGlyphsForCharacters(webFont, &alef, &glyph, 1)
                && CTFontGetGlyphsForCharacters(webFont, &space, &glyph, 1) == !subsetIndex, "web font subset: it has Hebrew and no U+034F, and a space only in the first subset");
            CFArrayRef emptyCascade = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
            CFTypeRef cascadeKeys[] = { kCTFontCascadeListAttribute };
            CFTypeRef cascadeValues[] = { emptyCascade };
            CFDictionaryRef cascadeAttributes = CFDictionaryCreate(NULL, cascadeKeys, cascadeValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CTFontDescriptorRef noCascade = CTFontDescriptorCreateWithAttributes(cascadeAttributes);
            CTFontRef variants[] = { webFont, CTFontCreateCopyWithAttributes(webFont, 24, NULL, noCascade) };
            // Latin the web font does not have set by fallback between the controls, and a right-to-left isolate
            // closed between Hebrew letters the web font does have.
            const UniChar fallbackBetween[] = { 0x05D1, 0x2066, 'a', 0x2069, 0x05D2, 0x2067, 0x05D3, 0x2066, 'b', 0x2069, 0x2069, 'c' };
            const UniChar fallbackBetweenWithout[] = { 0x05D1, 'a', 0x05D2, 0x05D3, 'b', 'c' };
            const UniChar coveredBetween[] = { 'x', 0x2067, 0x05D1, 0x05D2, 0x2069, 0x05D3 };
            const UniChar coveredBetweenWithout[] = { 'x', 0x05D1, 0x05D2, 0x05D3 };
            struct {
                const char *name;
                const UniChar *with;
                CFIndex withLength;
                const UniChar *without;
                CFIndex withoutLength;
            } webTexts[] = {
                { "controls around fallback Latin", fallbackBetween, 12, fallbackBetweenWithout, 6 },
                { "a right-to-left isolate closed between Hebrew letters", coveredBetween, 6, coveredBetweenWithout, 4 },
            };
            for (int v = 0; v < 2; ++v) {
                for (size_t w = 0; w < sizeof(webTexts) / sizeof(*webTexts); ++w) {
                    CFDictionaryRef webAttributes = attributesWithFont(variants[v]);
                    Text with = { webTexts[w].with, webTexts[w].withLength, { 0 }, { webAttributes }, 1, { 0 }, 0, 0, false };
                    Text without = { webTexts[w].without, webTexts[w].withoutLength, { 0 }, { webAttributes }, 1, { 0 }, 0, 0, false };
                    CTLineRef withLine = CTLineCreateWithUniCharProvider(provide, NULL, &with);
                    CTLineRef withoutLine = CTLineCreateWithUniCharProvider(provide, NULL, &without);
                    double difference = CTLineGetTypographicBounds(withLine, NULL, NULL, NULL) - CTLineGetTypographicBounds(withoutLine, NULL, NULL, NULL);
                    const char *cascade = subsetIndex ? (v ? "no space, empty cascade list" : "no space, CoreText's cascade") : (v ? "empty cascade list" : "CoreText's cascade");
                    char what[256];
                    snprintf(what, sizeof(what), "web font without U+034F, %s, %s: isolate controls add no width", cascade, webTexts[w].name);
                    check(difference < 0.01 && difference > -0.01, what);
                    snprintf(what, sizeof(what), "web font without U+034F, %s, %s: no .notdef", cascade, webTexts[w].name);
                    check(!hasNotdef(withLine), what);
                    snprintf(what, sizeof(what), "web font without U+034F, %s, %s: every run reports the font its glyphs come from", cascade, webTexts[w].name);
                    check(runsReportTheirGlyphsFonts(withLine, webTexts[w].with) && runsReportTheirGlyphsFonts(withoutLine, webTexts[w].without), what);
                    snprintf(what, sizeof(what), "web font without U+034F, %s, %s: the levels current Unicode resolves", cascade, webTexts[w].name);
                    check(matchesCurrentLevels(withLine, webTexts[w].with, webTexts[w].withLength, UBIDI_DEFAULT_LTR), what);
                    CFRelease(withLine);
                    CFRelease(withoutLine);
                    CFRelease(webAttributes);
                }
            }
            CFRelease(variants[1]);
            CFRelease(noCascade);
            CFRelease(cascadeAttributes);
            CFRelease(emptyCascade);
            CFRelease(webFont);
            CFRelease(descriptor);
        }
        if (sanitized)
            CFRelease(sanitized);
        CFRelease(subset);
        }
        CFRelease(arialHebrew);
    }

    const UniChar latinOnly[] = { 'o', 'f', 'f', 'i', 'c', 'e', ' ', 'a', 0x0301 };
    text = (Text) { latinOnly, 9, { 0 }, { latin }, 1, { 0 }, 0, 0, false };
    line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    readLine(line, &rtl);
    CFRelease(line);
    shapeNative(latinOnly, 9, times, 0, &native);
    check(sameGlyphs(&rtl, native.glyphs, native.glyphCount), "natural direction, Latin: the attributed-string typesetting");

    // In natural direction a keycap led by #, with and without its emoji selector, resolves right to left
    // between Hebrew letters, and forms its ligature there as a line and from a typesetter with no forced level.
    CFDictionaryRef noOptions = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const UniChar keycapsBetweenHebrew[] = { 0x05D0, '#', 0xFE0F, 0x20E3, '#', 0x20E3, 0x05D1 };
    CGGlyph keycapGlyphs[2];
    shapeNative(keycapsBetweenHebrew + 1, 3, logicalFont, 0, &ltr);
    keycapGlyphs[0] = ltr.glyphCount == 1 ? ltr.glyphs[0] : 0;
    shapeNative(keycapsBetweenHebrew + 4, 2, logicalFont, 0, &ltr);
    keycapGlyphs[1] = ltr.glyphCount == 1 ? ltr.glyphs[0] : 0;
    check(keycapGlyphs[0] && keycapGlyphs[1], "keycaps led by #, left to right: one glyph each");
    for (int route = 0; route < 2; ++route) {
        text = (Text) { keycapsBetweenHebrew, 7, { 0, 1, 6 }, { hebrew, logical, hebrew }, 3, { 0 }, 0, 0, false };
        CTTypesetterRef naturalTypesetter = route ? CTTypesetterCreateWithUniCharProviderAndOptions(provide, dispose, &text, noOptions) : NULL;
        line = route ? CTTypesetterCreateLine(naturalTypesetter, CFRangeMake(0, 0)) : CTLineCreateWithUniCharProvider(provide, dispose, &text);
        readLine(line, &rtl);
        bool keycapsLigated = false;
        for (CFIndex i = 0; i + 1 < rtl.glyphCount; ++i)
            keycapsLigated = keycapsLigated || (rtl.glyphs[i] == keycapGlyphs[1] && rtl.glyphs[i + 1] == keycapGlyphs[0]);
        const char *routeName = route ? "typesetter with no forced level" : "line";
        char what[256];
        snprintf(what, sizeof(what), "%s, keycaps between Hebrew letters: both ligatures, right to left", routeName);
        check(keycapsLigated && rtl.glyphCount == 4, what);
        snprintf(what, sizeof(what), "%s, keycaps between Hebrew letters: runs tile the text and report the provided attributes", routeName);
        check(rangesTile(&rtl, 7) && reportsProvidedAttributes(&rtl, &text), what);
        CFRelease(line);
        int providedBeforeRelease = text.providedCount;
        if (naturalTypesetter)
            CFRelease(naturalTypesetter);
        snprintf(what, sizeof(what), "%s, keycaps between Hebrew letters: each block handed out is disposed of once", routeName);
        check(text.disposedCount == providedBeforeRelease && !text.disposedUnprovided, what);
    }
    CFRelease(noOptions);

    // A forced right-to-left level and natural direction set the same fonts and glyphs, including where
    // CoreText falls back from the block's font: * is not in the logical-order font.
    {
        const UniChar fallbackBetweenHebrew[] = { 0x05D0, '#', 0xFE0F, 0x20E3, '*', 0xFE0F, 0x20E3, 0x05D1 };
        text = (Text) { fallbackBetweenHebrew, 8, { 0, 1, 7 }, { hebrew, logical, hebrew }, 3, { 0 }, 0, 0, false };
        Shape forced, naturalShape;
        shapeForced(&text, 1, &forced);
        CTLineRef naturalLine = CTLineCreateWithUniCharProvider(provide, NULL, &text);
        readLine(naturalLine, &naturalShape);
        CFRelease(naturalLine);
        bool sameFonts = forced.runCount == naturalShape.runCount;
        for (CFIndex r = 0; sameFonts && r < forced.runCount; ++r) {
            CFStringRef a = CTFontCopyPostScriptName((CTFontRef)CFDictionaryGetValue(forced.attributes[r], kCTFontAttributeName));
            CFStringRef b = CTFontCopyPostScriptName((CTFontRef)CFDictionaryGetValue(naturalShape.attributes[r], kCTFontAttributeName));
            sameFonts = CFEqual(a, b) && forced.ranges[r].location == naturalShape.ranges[r].location && forced.ranges[r].length == naturalShape.ranges[r].length;
            CFRelease(a);
            CFRelease(b);
        }
        check(sameFonts && sameGlyphs(&forced, naturalShape.glyphs, naturalShape.glyphCount),
            "fallback between Hebrew letters: a forced right-to-left level sets what natural direction sets");
        bool hashLigated = false;
        for (CFIndex i = 0; i < forced.glyphCount; ++i)
            hashLigated = hashLigated || forced.glyphs[i] == keycapGlyphs[0];
        check(hashLigated, "fallback between Hebrew letters: the keycap in the logical-order font forms its ligature");
    }

    checkBidiDataPremises();
    // The installed Apple Color Emoji, when it carries the flag: skin tone and a ZWJ family set in Times
    // right to left, reaching the emoji font by fallback, and the instance leaving the images out.
    CTFontRef emoji = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 16, NULL);
    if (fontHasLogicalOrderSubtables(emoji)) {
        double before = internalMegabytes();
        const UniChar thumb[] = { 0xD83D, 0xDC4D, 0xD83C, 0xDFFE };
        const UniChar family[] = { 0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67 };
        const UniChar keycapInTimes[] = { 0x05D0, '1', 0xFE0F, 0x20E3 };
        CFDictionaryRef emojiAttributes = attributesWithFont(emoji);
        text = (Text) { thumb, 4, { 0 }, { emojiAttributes }, 1, { 0 }, 0, 0, false };
        shapeForced(&text, 1, &rtl);
        shapeNative(thumb, 4, emoji, 0, &ltr);
        check(ltr.glyphCount == 1 && sameGlyphs(&rtl, ltr.glyphs, 1) && rtl.width == ltr.width, "installed emoji, skin tone, right to left: one glyph");
        check(rtl.attributes[0] == emojiAttributes, "installed emoji: the run reports the provided attributes");

        text = (Text) { family, 8, { 0 }, { latin }, 1, { 0 }, 0, 0, false };
        shapeForced(&text, 1, &rtl);
        shapeNative(family, 8, emoji, 0, &ltr);
        check(ltr.glyphCount == 1 && sameGlyphs(&rtl, ltr.glyphs, 1), "installed emoji, family set in Times, right to left: one glyph");
        // The shaping instance is built from table data and has no file; the font the run reports does.
        CTFontRef reported = rtl.runCount == 1 ? (CTFontRef)CFDictionaryGetValue(rtl.attributes[0], kCTFontAttributeName) : NULL;
        CFStringRef name = reported ? CTFontCopyPostScriptName(reported) : NULL;
        CFTypeRef url = reported ? CTFontCopyAttribute(reported, kCTFontURLAttribute) : NULL;
        CFTypeRef emojiURL = CTFontCopyAttribute(emoji, kCTFontURLAttribute);
        check(name && CFEqual(name, CFSTR("AppleColorEmoji")) && url && emojiURL && CFEqual(url, emojiURL),
            "installed emoji, family set in Times: the run reports Apple Color Emoji itself");
        if (name)
            CFRelease(name);
        if (url)
            CFRelease(url);
        if (emojiURL)
            CFRelease(emojiURL);

        text = (Text) { keycapInTimes, 4, { 0 }, { latin }, 1, { 0 }, 0, 0, false };
        shapeForced(&text, 1, &rtl);
        shapeNative(keycapInTimes + 1, 3, emoji, 0, &ltr);
        bool keycapLigated = false;
        for (CFIndex i = 0; i < rtl.glyphCount; ++i)
            keycapLigated = keycapLigated || rtl.glyphs[i] == ltr.glyphs[0];
        check(ltr.glyphCount == 1 && keycapLigated && rtl.glyphCount == 2, "installed emoji, keycap set in Times after a Hebrew letter, right to left: the ligature");
        // An emoji modifier between Hebrew letters, in natural direction: one right-to-left run, one glyph.
        CFDictionaryRef hebrewInEmoji = attributesWithFont(emoji);
        const UniChar thumbBetweenHebrew[] = { 0x05D0, 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, 0x05D1 };
        text = (Text) { thumbBetweenHebrew, 6, { 0, 1, 5 }, { hebrew, hebrewInEmoji, hebrew }, 3, { 0 }, 0, 0, false };
        line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
        readLine(line, &rtl);
        CFRelease(line);
        shapeNative(thumb, 4, emoji, 0, &ltr);
        bool thumbLigated = false;
        for (CFIndex i = 0; i < rtl.glyphCount; ++i)
            thumbLigated = thumbLigated || rtl.glyphs[i] == ltr.glyphs[0];
        check(thumbLigated && rtl.glyphCount == 3 && rtl.runCount == 3, "installed emoji, skin tone between Hebrew letters, natural direction: one run, one glyph");
        CFRelease(hebrewInEmoji);
        check(internalMegabytes() - before < 16, "installed emoji: shaping right to left does not copy the glyph images");
        CFRelease(emojiAttributes);
    } else
        printf("installed Apple Color Emoji has no logical-order subtable; its cases are not run\n");

    if (failures)
        return 1;
    printf("logical order: all cases match\n");
    return 0;
}
