// CTFontShapeGlyphs (polyfills/c/CoreText.c) called the way WebCore's Font::applyTransforms calls it:
// nominal glyphs, float advances, 0-based string indexes, and a handler that grows and shrinks the
// buffers. A run whose shaping depends on its characters -- the script, language, default-ignorable character,
// or a positioning feature the font's settings request -- is set the way 10.9 sets the same characters in
// a CTLine; every other run keeps the glyph transform.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

extern CGSize CTFontShapeGlyphs(CTFontRef, CGGlyph[], CGSize[], CGPoint[], CFIndex[], const UniChar[], CFIndex,
    CFOptionFlags, CFStringRef, void (^)(CFRange, CGGlyph **, CGSize **, CGPoint **, CFIndex **));

enum { Capacity = 256, ShapeWithKerning = 1 << 0, ShapeWithClusterComposition = 1 << 1 };

typedef struct {
    CGGlyph glyphs[Capacity];
    CGSize advances[Capacity];
    CGPoint origins[Capacity];
    CFIndex indexes[Capacity];
    CFIndex count;
    double width;
} Shaped;

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

static void removeSlots(Shaped *run, CFIndex at, CFIndex length)
{
    CFIndex tail = run->count - at - length;
    memmove(run->glyphs + at, run->glyphs + at + length, (size_t)tail * sizeof(CGGlyph));
    memmove(run->advances + at, run->advances + at + length, (size_t)tail * sizeof(CGSize));
    memmove(run->origins + at, run->origins + at + length, (size_t)tail * sizeof(CGPoint));
    memmove(run->indexes + at, run->indexes + at + length, (size_t)tail * sizeof(CFIndex));
    run->count -= length;
}

static void insertSlots(Shaped *run, CFIndex at, CFIndex length)
{
    CFIndex tail = run->count - at;
    memmove(run->glyphs + at + length, run->glyphs + at, (size_t)tail * sizeof(CGGlyph));
    memmove(run->advances + at + length, run->advances + at, (size_t)tail * sizeof(CGSize));
    memmove(run->origins + at + length, run->origins + at, (size_t)tail * sizeof(CGPoint));
    memmove(run->indexes + at + length, run->indexes + at, (size_t)tail * sizeof(CFIndex));
    memset(run->glyphs + at, 0, (size_t)length * sizeof(CGGlyph));
    memset(run->advances + at, 0, (size_t)length * sizeof(CGSize));
    memset(run->origins + at, 0, (size_t)length * sizeof(CGPoint));
    memset(run->indexes + at, 0, (size_t)length * sizeof(CFIndex));
    run->count += length;
}

static void shapeDirection(Shaped *run, CTFontRef font, const UniChar *characters, CFIndex length, CFStringRef language, bool kerning, bool rtl)
{
    CTFontGetGlyphsForCharacters(font, characters, run->glyphs, length);
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, run->glyphs, run->advances, length);
    for (CFIndex i = 0; i < length; i++) {
        run->advances[i] = CGSizeMake((float)run->advances[i].width, 0);
        run->origins[i] = CGPointZero;
        run->indexes[i] = i;
    }
    run->count = length;
    CGSize initialAdvance = CTFontShapeGlyphs(font, run->glyphs, run->advances, run->origins, run->indexes, characters, length,
        ShapeWithClusterComposition | (kerning ? ShapeWithKerning : 0) | (rtl ? 1 << 2 : 0), language,
        ^(CFRange range, CGGlyph **glyphs, CGSize **advances, CGPoint **origins, CFIndex **indexes) {
            CFIndex location = range.location < 0 ? 0 : (range.location > run->count ? run->count : range.location);
            if (range.length < 0) {
                CFIndex removed = -range.length < location ? -range.length : location;
                removeSlots(run, location - removed, removed);
            } else
                insertSlots(run, location, range.length);
            *glyphs = run->glyphs;
            *advances = run->advances;
            *origins = run->origins;
            *indexes = run->indexes;
        });
    run->width = initialAdvance.width;
    for (CFIndex i = 0; i < run->count; i++)
        run->width += run->advances[i].width;
}

static void shape(Shaped *run, CTFontRef font, const UniChar *characters, CFIndex length, CFStringRef language, bool kerning)
{
    shapeDirection(run, font, characters, length, language, kerning, false);
}

// The same characters set by 10.9 itself in a CTLine: the glyphs and width the run must match.
static void setInLineDirection(Shaped *run, CTFontRef font, const UniChar *characters, CFIndex length, CFStringRef language, bool rtl)
{
    CFStringRef string = CFStringCreateWithCharacters(NULL, characters, length);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontAttributeName, font);
    if (language)
        CFDictionarySetValue(attributes, kCTLanguageAttributeName, language);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    int level = rtl ? 1 : 0;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &level);
    const void *keys[] = { kCTTypesetterOptionForcedEmbeddingLevel };
    const void *values[] = { number };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributed, options);
    CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
    CFRelease(typesetter);
    CFRelease(options);
    CFRelease(number);
    run->count = 0;
    run->width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef glyphRun = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex count = CTRunGetGlyphCount(glyphRun);
        CGGlyph glyphs[Capacity];
        CFIndex indices[Capacity];
        CTRunGetStringIndices(glyphRun, CFRangeMake(0, count), indices);
        CTRunGetGlyphs(glyphRun, CFRangeMake(0, count), glyphs);
        for (CFIndex i = 0; i < count && run->count < Capacity; i++) {
            run->indexes[run->count] = indices[i];
            run->glyphs[run->count++] = glyphs[i];
        }
    }
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
}

static bool sameGlyphs(const Shaped *a, const Shaped *b)
{
    return a->count == b->count && !memcmp(a->glyphs, b->glyphs, (size_t)a->count * sizeof(CGGlyph));
}

static void expectLikeLine(const char *what, CTFontRef font, const UniChar *characters, CFIndex length, CFStringRef language, bool kerning)
{
    Shaped shaped, line;
    shape(&shaped, font, characters, length, language, kerning);
    setInLineDirection(&line, font, characters, length, language, false);
    char label[160];
    snprintf(label, sizeof(label), "%s: glyphs match a CTLine", what);
    check(sameGlyphs(&shaped, &line), label);
    if (kerning) {
        snprintf(label, sizeof(label), "%s: width %.2f matches a CTLine's %.2f", what, shaped.width, line.width);
        check(shaped.width > line.width - 0.01 && shaped.width < line.width + 0.01, label);
    }
}

// Four box glyphs. cyrl DefaultLangSys ligates A B; DFLT/latn ligate B A. The cmap maps U+0410/U+0411.
static const uint8_t scriptFixture[] = {
    0x00, 0x01, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x80, 0x00, 0x03, 0x00, 0x30, 0x47, 0x53, 0x55, 0x42,
    0x64, 0x59, 0x60, 0x7e, 0x00, 0x00, 0x03, 0x68, 0x00, 0x00, 0x00, 0xb0, 0x4f, 0x53, 0x2f, 0x32,
    0x4a, 0xef, 0x47, 0xa3, 0x00, 0x00, 0x01, 0x38, 0x00, 0x00, 0x00, 0x60, 0x63, 0x6d, 0x61, 0x70,
    0x00, 0x0c, 0x04, 0x64, 0x00, 0x00, 0x01, 0xa4, 0x00, 0x00, 0x00, 0x34, 0x67, 0x6c, 0x79, 0x66,
    0x49, 0x38, 0xdc, 0x00, 0x00, 0x00, 0x01, 0xe4, 0x00, 0x00, 0x00, 0x60, 0x68, 0x65, 0x61, 0x64,
    0x2e, 0x44, 0xca, 0x2e, 0x00, 0x00, 0x00, 0xbc, 0x00, 0x00, 0x00, 0x36, 0x68, 0x68, 0x65, 0x61,
    0x04, 0xb2, 0x01, 0x92, 0x00, 0x00, 0x00, 0xf4, 0x00, 0x00, 0x00, 0x24, 0x68, 0x6d, 0x74, 0x78,
    0x01, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x01, 0x98, 0x00, 0x00, 0x00, 0x0a, 0x6c, 0x6f, 0x63, 0x61,
    0x00, 0x48, 0x00, 0x30, 0x00, 0x00, 0x01, 0xd8, 0x00, 0x00, 0x00, 0x0a, 0x6d, 0x61, 0x78, 0x70,
    0x00, 0x06, 0x00, 0x06, 0x00, 0x00, 0x01, 0x18, 0x00, 0x00, 0x00, 0x20, 0x6e, 0x61, 0x6d, 0x65,
    0x1a, 0x02, 0xa0, 0xca, 0x00, 0x00, 0x02, 0x44, 0x00, 0x00, 0x00, 0xf3, 0x70, 0x6f, 0x73, 0x74,
    0x43, 0x2c, 0x02, 0x66, 0x00, 0x00, 0x03, 0x38, 0x00, 0x00, 0x00, 0x2d, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x48, 0x5a, 0x51, 0x55, 0x5f, 0x0f, 0x3c, 0xf5, 0x00, 0x03, 0x03, 0xe8,
    0x00, 0x00, 0x00, 0x00, 0xe6, 0xcf, 0x43, 0x49, 0x00, 0x00, 0x00, 0x00, 0xe6, 0xcf, 0x43, 0x49,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x90, 0x02, 0xbc, 0x00, 0x00, 0x00, 0x03, 0x00, 0x02, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x03, 0x20, 0xff, 0x38, 0x00, 0x00, 0x01, 0xf4,
    0x00, 0x00, 0x00, 0x64, 0x01, 0x90, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0xf4, 0x01, 0x90, 0x00, 0x05,
    0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x3f, 0x3f, 0x3f, 0x3f, 0x00, 0x00, 0x04, 0x10, 0x04, 0x11, 0x03, 0x20, 0xff, 0x38,
    0x00, 0x00, 0x03, 0x20, 0x00, 0xc8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x02, 0x01, 0xf4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x14,
    0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x04, 0x00, 0x20, 0x00, 0x00, 0x00, 0x04,
    0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x04, 0x11, 0xff, 0xff, 0x00, 0x00, 0x04, 0x10, 0xff, 0xff,
    0xfb, 0xf1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x18, 0x00, 0x24,
    0x00, 0x30, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x90, 0x02, 0xbc, 0x00, 0x03,
    0x00, 0x00, 0x31, 0x21, 0x11, 0x21, 0x01, 0x90, 0xfe, 0x70, 0x02, 0xbc, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x90, 0x02, 0xbc, 0x00, 0x03, 0x00, 0x00, 0x31, 0x21, 0x11, 0x21, 0x01, 0x90,
    0xfe, 0x70, 0x02, 0xbc, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x90, 0x02, 0xbc, 0x00, 0x03,
    0x00, 0x00, 0x31, 0x21, 0x11, 0x21, 0x01, 0x90, 0xfe, 0x70, 0x02, 0xbc, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x90, 0x02, 0xbc, 0x00, 0x03, 0x00, 0x00, 0x31, 0x21, 0x11, 0x21, 0x01, 0x90,
    0xfe, 0x70, 0x02, 0xbc, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x7e, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x11, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x07,
    0x00, 0x11, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x0f, 0x00, 0x18, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x11, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x06, 0x00, 0x0f, 0x00, 0x18, 0x00, 0x03, 0x00, 0x01, 0x04, 0x09, 0x00, 0x01, 0x00, 0x22,
    0x00, 0x27, 0x00, 0x03, 0x00, 0x01, 0x04, 0x09, 0x00, 0x02, 0x00, 0x0e, 0x00, 0x49, 0x00, 0x03,
    0x00, 0x01, 0x04, 0x09, 0x00, 0x03, 0x00, 0x1e, 0x00, 0x57, 0x00, 0x03, 0x00, 0x01, 0x04, 0x09,
    0x00, 0x04, 0x00, 0x22, 0x00, 0x27, 0x00, 0x03, 0x00, 0x01, 0x04, 0x09, 0x00, 0x06, 0x00, 0x1e,
    0x00, 0x57, 0x57, 0x4b, 0x20, 0x53, 0x63, 0x72, 0x69, 0x70, 0x74, 0x20, 0x43, 0x6f, 0x6e, 0x74,
    0x65, 0x78, 0x74, 0x52, 0x65, 0x67, 0x75, 0x6c, 0x61, 0x72, 0x57, 0x4b, 0x53, 0x63, 0x72, 0x69,
    0x70, 0x74, 0x43, 0x6f, 0x6e, 0x74, 0x65, 0x78, 0x74, 0x00, 0x57, 0x00, 0x4b, 0x00, 0x20, 0x00,
    0x53, 0x00, 0x63, 0x00, 0x72, 0x00, 0x69, 0x00, 0x70, 0x00, 0x74, 0x00, 0x20, 0x00, 0x43, 0x00,
    0x6f, 0x00, 0x6e, 0x00, 0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00, 0x52, 0x00, 0x65, 0x00,
    0x67, 0x00, 0x75, 0x00, 0x6c, 0x00, 0x61, 0x00, 0x72, 0x00, 0x57, 0x00, 0x4b, 0x00, 0x53, 0x00,
    0x63, 0x00, 0x72, 0x00, 0x69, 0x00, 0x70, 0x00, 0x74, 0x00, 0x43, 0x00, 0x6f, 0x00, 0x6e, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x24, 0x00, 0x25,
    0x01, 0x02, 0x02, 0x41, 0x42, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x42,
    0x00, 0x68, 0x00, 0x03, 0x44, 0x46, 0x4c, 0x54, 0x00, 0x14, 0x63, 0x79, 0x72, 0x6c, 0x00, 0x20,
    0x6c, 0x61, 0x74, 0x6e, 0x00, 0x2c, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x01, 0x00, 0x01, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x6c, 0x69, 0x67, 0x61,
    0x00, 0x14, 0x6c, 0x69, 0x67, 0x61, 0x00, 0x1a, 0x6c, 0x69, 0x67, 0x61, 0x00, 0x20, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01,
    0x00, 0x03, 0x00, 0x08, 0x00, 0x08, 0x00, 0x28, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08,
    0x00, 0x01, 0x00, 0x12, 0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x04, 0x00, 0x03, 0x00, 0x02,
    0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08,
    0x00, 0x01, 0x00, 0x12, 0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x04, 0x00, 0x03, 0x00, 0x02,
    0x00, 0x02, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01,
};

static CTFontRef fontFromFile(const char *path, CGFloat size)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFDataRef data = NULL;
    CFURLCreateDataAndPropertiesFromResource(NULL, url, &data, NULL, NULL, NULL);
    CFRelease(url);
    if (!data)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(data);
    CFRelease(data);
    if (!descriptor)
        return NULL;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CFRelease(descriptor);
    return font;
}

static CTFontRef fontWithOpenTypeFeature(CTFontRef base, CFStringRef tag, int value)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    // The polyfill layer supplies both keys on 10.9.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    const void *featureKeys[] = { kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue };
#pragma clang diagnostic pop
    const void *featureValues[] = { tag, number };
    CFDictionaryRef feature = CFDictionaryCreate(NULL, featureKeys, featureValues, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *features[] = { feature };
    CFArrayRef settings = CFArrayCreate(NULL, features, 1, &kCFTypeArrayCallBacks);
    const void *attributeKeys[] = { kCTFontFeatureSettingsAttribute };
    const void *attributeValues[] = { settings };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, attributeKeys, attributeValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef baseDescriptor = CTFontCopyFontDescriptor(base);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(baseDescriptor, attributes);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(base), NULL);
    CFRelease(descriptor);
    CFRelease(baseDescriptor);
    CFRelease(attributes);
    CFRelease(settings);
    CFRelease(feature);
    CFRelease(number);
    return font;
}

typedef const UniChar *(*CTUniCharProviderCallback)(CFIndex, CFIndex *, CFDictionaryRef *, void *);
typedef void (*CTUniCharDisposeCallback)(const UniChar *, void *);
extern CTLineRef CTLineCreateWithUniCharProvider(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *);
extern CTTypesetterRef CTTypesetterCreateWithUniCharProviderAndOptions(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *, CFDictionaryRef);

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <web-platform-tests directory>\n", argv[0]);
        return 2;
    }
    char path[1024];

    // Language: Lato's latn TRK language system drops the fi ligature; its default one keeps it.
    snprintf(path, sizeof(path), "%s/fonts/Lato-Medium.ttf", argv[1]);
    CTFontRef lato = fontFromFile(path, 50);
    check(lato, "Lato-Medium.ttf loads");
    const UniChar fi[] = { 'f', 'i' };
    const UniChar greekThenFi[] = { 0x03B1, 0x03B2, ' ', 'f', 'i' };
    if (lato) {
        Shaped english, turkish;
        shape(&english, lato, fi, 2, CFSTR("en"), true);
        shape(&turkish, lato, fi, 2, CFSTR("tr"), true);
        check(english.count == 1, "Lato fi under en forms the ligature");
        check(turkish.count == 2, "Lato fi under tr keeps two glyphs");
        expectLikeLine("Lato fi, tr", lato, fi, 2, CFSTR("tr"), true);
        expectLikeLine("Lato fi, en", lato, fi, 2, CFSTR("en"), true);
        expectLikeLine("Lato Greek then fi, tr", lato, greekThenFi, 5, CFSTR("tr"), true);
    }

    // Language: Comic Sans MS's latn LTH language system substitutes the accented i.
    CTFontRef comic = CTFontCreateWithName(CFSTR("ComicSansMS"), 100, NULL);
    const UniChar iAcute[] = { 0x00ED, 0x00ED };
    Shaped lithuanian, unmarked;
    shape(&lithuanian, comic, iAcute, 2, CFSTR("lt"), true);
    shape(&unmarked, comic, iAcute, 2, NULL, true);
    check(lithuanian.count == 2 && unmarked.count == 2 && lithuanian.glyphs[0] != unmarked.glyphs[0],
        "Comic Sans i-acute under lt takes the Lithuanian form");
    expectLikeLine("Comic Sans i-acute, lt", comic, iAcute, 2, CFSTR("lt"), true);

    // Default-ignorable: 10.9 forms Times' fi ligature through U+200D.
    CTFontRef times = CTFontCreateWithName(CFSTR("Times-Roman"), 40, NULL);
    const UniChar fJoinerI[] = { 'f', 0x200D, 'i' };
    Shaped joined;
    shape(&joined, times, fJoinerI, 3, CFSTR("en"), true);
    check(joined.count == 1, "Times f U+200D i forms one glyph");
    expectLikeLine("Times f U+200D i", times, fJoinerI, 3, CFSTR("en"), true);

    const UniChar invisible[] = { 0x200B, 0x200B, 0x200B };
    for (CFIndex length = 1; length <= 3; ++length) {
        for (int rtl = 0; rtl <= 1; ++rtl) {
            Shaped run, line;
            shapeDirection(&run, times, invisible, length, NULL, true, rtl);
            setInLineDirection(&line, times, invisible, length, NULL, rtl);
            printf("default-ignorable length %ld rtl %d: %ld glyphs, width %.2f\n", length, rtl, run.count, run.width);
            check(run.count > 0 && sameGlyphs(&run, &line), "a default-ignorable run retains the typesetter glyphs");
            check(run.width == 0, "a default-ignorable run has zero width");
            for (CFIndex i = 0; i < run.count; ++i) {
                check(run.glyphs[i] == 0xFFFF && run.advances[i].width == 0,
                    "the typesetter's invisible glyph retains its zero advance");
                check(run.origins[i].x == 0 && run.origins[i].y == 0,
                    "the invisible glyph has zero origin");
                check(run.indexes[i] == line.indexes[i],
                    "invisible glyph indices match the typesetter at the requested direction");
            }
        }
    }

    // Positioning feature: Hiragino Kaku Gothic ProN's palt narrows proportional kana.
    CTFontRef hiragino = CTFontCreateWithName(CFSTR("HiraKakuProN-W3"), 48, NULL);
    const UniChar kana[] = { 0x30C6, 0x30A3, 0x30C6, 0x30A3, 0x30C6, 0x30A3, 0x30C6, 0x30A3 };
    CTFontRef proportional = fontWithOpenTypeFeature(hiragino, CFSTR("palt"), 1);
    CTFontRef fullWidth = fontWithOpenTypeFeature(hiragino, CFSTR("palt"), 0);
    Shaped narrowed, full;
    shape(&narrowed, proportional, kana, 8, CFSTR("ja"), true);
    shape(&full, fullWidth, kana, 8, CFSTR("ja"), true);
    char label[160];
    snprintf(label, sizeof(label), "Hiragino kana with palt 1 (%.2f) is narrower than with palt 0 (%.2f)", narrowed.width, full.width);
    check(narrowed.width < full.width - 1, label);
    expectLikeLine("Hiragino kana, palt 1", proportional, kana, 8, CFSTR("ja"), true);

    CFDataRef scriptData = CFDataCreate(NULL, scriptFixture, sizeof(scriptFixture));
    CTFontDescriptorRef scriptDescriptor = CTFontManagerCreateFontDescriptorFromData(scriptData);
    check(scriptDescriptor, "the script-only ligature fixture sanitizes");
    if (scriptDescriptor) {
        CTFontRef scriptFont = CTFontCreateWithFontDescriptor(scriptDescriptor, 48, NULL);
        const UniChar cyrillic[] = { 0x0410, 0x0411 };
        Shaped shaped, line;
        shape(&shaped, scriptFont, cyrillic, 2, NULL, true);
        setInLineDirection(&line, scriptFont, cyrillic, 2, NULL, false);
        check(shaped.count == 1 && sameGlyphs(&shaped, &line), "cyrl DefaultLangSys forms the character route's ligature");
        extern bool CTFontTransformGlyphs(CTFontRef, CGGlyph[], CGSize[], CFIndex, uint32_t);
        CGGlyph rawGlyphs[2]; CGSize rawAdvances[2];
        CTFontGetGlyphsForCharacters(scriptFont, cyrillic, rawGlyphs, 2);
        CTFontGetAdvancesForGlyphs(scriptFont, kCTFontOrientationHorizontal, rawGlyphs, rawAdvances, 2);
        CTFontTransformGlyphs(scriptFont, rawGlyphs, rawAdvances, 2, 3);
        printf("script-only cyrl: shape %ld glyphs, CTLine %ld glyphs; glyph-only transform %u,%u\n", shaped.count, line.count, rawGlyphs[0], rawGlyphs[1]);
        check(rawGlyphs[0] == 1 && rawGlyphs[1] == 2, "the glyph-only Latin route misses the cyrl DefaultLangSys ligature");
        CFRelease(scriptFont); CFRelease(scriptDescriptor);
    }
    CFRelease(scriptData);
    CTFontRef arabic = CTFontCreateWithName(CFSTR("GeezaPro"), 48, NULL);
    const UniChar joinedArabic[] = { 0x0628, 0x200D, 0x0628 };
    Shaped rtl, rtlLine;
    shapeDirection(&rtl, arabic, joinedArabic, 3, CFSTR("ar"), true, true);
    setInLineDirection(&rtlLine, arabic, joinedArabic, 3, CFSTR("ar"), true);
    check(sameGlyphs(&rtl, &rtlLine), "Arabic with ZWJ at embedding level 1 matches CTLine glyphs");
    check(rtl.count == rtlLine.count && !memcmp(rtl.indexes, rtlLine.indexes, rtl.count * sizeof(CFIndex)),
        "Arabic with ZWJ keeps the CTLine visual string indices");
    check(fabs(rtl.width - rtlLine.width) < 0.01, "Arabic with ZWJ keeps the CTLine width");
    CFRelease(arabic);

    // Runs with nothing character-dependent keep the transform's results.
    CTFontRef hoefler = CTFontCreateWithName(CFSTR("HoeflerText-Regular"), 40, NULL);
    Shaped ligature;
    shape(&ligature, hoefler, fi, 2, NULL, true);
    check(ligature.count == 1, "Hoefler Text fi forms its ligature");
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 48, NULL);
    const UniChar avav[] = { 'A', 'V', 'A', 'V' };
    Shaped kerned, unkerned;
    shape(&kerned, helvetica, avav, 4, CFSTR("en"), true);
    shape(&unkerned, helvetica, avav, 4, CFSTR("en"), false);
    check(kerned.width < unkerned.width - 1, "Helvetica AVAV kerns only when asked");
    CTFontRef arial = CTFontCreateWithName(CFSTR("ArialMT"), 40, NULL);
    const UniChar word[] = { 'o', 'f', 'f', 'i', 'c', 'e' };
    expectLikeLine("Arial office, en", arial, word, 6, CFSTR("en"), true);

    // A right-to-left run arrives in logical order and comes back in visual order, with each glyph's string
    // index, which WebCore reverses back (Font::applyTransforms).
    const UniChar abc[] = { 'a', 'b', 'c' };
    Shaped forward, backward;
    shape(&forward, times, abc, 3, NULL, true);
    CGGlyph logical[3];
    CTFontGetGlyphsForCharacters(times, abc, logical, 3);
    CTFontGetAdvancesForGlyphs(times, kCTFontOrientationHorizontal, logical, backward.advances, 3);
    for (CFIndex i = 0; i < 3; i++) {
        backward.glyphs[i] = logical[i];
        backward.advances[i] = CGSizeMake((float)backward.advances[i].width, 0);
        backward.origins[i] = CGPointZero;
        backward.indexes[i] = i;
    }
    backward.count = 3;
    Shaped *run = &backward;
    CTFontShapeGlyphs(times, backward.glyphs, backward.advances, backward.origins, backward.indexes, abc, 3,
        ShapeWithClusterComposition | ShapeWithKerning | (1 << 2), NULL,
        ^(CFRange range, CGGlyph **glyphs, CGSize **advances, CGPoint **origins, CFIndex **indexes) {
            if (range.length < 0)
                removeSlots(run, range.location + range.length, -range.length);
            else
                insertSlots(run, range.location, range.length);
            *glyphs = run->glyphs;
            *advances = run->advances;
            *origins = run->origins;
            *indexes = run->indexes;
        });
    check(backward.count == 3 && backward.glyphs[0] == logical[2] && backward.glyphs[1] == logical[1] && backward.glyphs[2] == logical[0],
        "Times abc right to left comes back in visual order");
    check(backward.count == 3 && backward.indexes[0] == 2 && backward.indexes[1] == 1 && backward.indexes[2] == 0,
        "Times abc right to left keeps each glyph's string index");
    const UniChar commaSpace[] = { ',', ' ' };
    Shaped neutral;
    CGGlyph neutralLogical[2];
    CTFontGetGlyphsForCharacters(times, commaSpace, neutralLogical, 2);
    CTFontGetAdvancesForGlyphs(times, kCTFontOrientationHorizontal, neutralLogical, neutral.advances, 2);
    for (CFIndex i = 0; i < 2; i++) {
        neutral.glyphs[i] = neutralLogical[i];
        neutral.advances[i] = CGSizeMake((float)neutral.advances[i].width, 0);
        neutral.origins[i] = CGPointZero;
        neutral.indexes[i] = i;
    }
    neutral.count = 2;
    CTFontShapeGlyphs(times, neutral.glyphs, neutral.advances, neutral.origins, neutral.indexes, commaSpace, 2,
        ShapeWithClusterComposition | ShapeWithKerning | (1 << 2), CFSTR("en"), NULL);
    check(neutral.glyphs[0] == neutralLogical[1] && neutral.glyphs[1] == neutralLogical[0],
        "Times comma space right to left, without a handler, comes back in visual order");

    if (failures)
        return 1;
    printf("shape glyphs character context: all cases match\n");
    return 0;
}
