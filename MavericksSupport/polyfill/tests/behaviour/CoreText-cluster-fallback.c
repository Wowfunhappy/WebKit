// CTLineCreateWithUniCharProvider and CTTypesetterCreateWithUniCharProviderAndOptions: an emoji ZWJ
// sequence set in Times arrives in one font and forms its ligature; text whose clusters 10.9 keeps whole
// is typeset exactly as CTLineCreateWithAttributedString typesets it; a dispose callback sees every block.

#include <ApplicationServices/ApplicationServices.h>

#include <stdio.h>
#include <string.h>

typedef const UniChar *(*CTUniCharProviderCallback)(CFIndex, CFIndex *, CFDictionaryRef *, void *);
typedef void (*CTUniCharDisposeCallback)(const UniChar *, void *);
extern CTLineRef CTLineCreateWithUniCharProvider(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *);
extern CTTypesetterRef CTTypesetterCreateWithUniCharProviderAndOptions(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *, CFDictionaryRef);

static int failures;

typedef struct {
    const UniChar *characters;
    CFIndex length;
    CFDictionaryRef attributes;
    int provided;
    int disposed;
} Text;

static const UniChar *provide(CFIndex index, CFIndex *count, CFDictionaryRef *attributes, void *refCon)
{
    Text *text = (Text *)refCon;
    if (index < 0 || index >= text->length) {
        *count = 0;
        return NULL;
    }
    ++text->provided;
    *count = text->length - index;
    *attributes = text->attributes;
    return text->characters + index;
}

static void dispose(const UniChar *characters, void *refCon)
{
    (void)characters;
    ++((Text *)refCon)->disposed;
}

static CFDictionaryRef attributesWithFont(const char *postScriptName)
{
    CFStringRef name = CFStringCreateWithCString(NULL, postScriptName, kCFStringEncodingASCII);
    CTFontRef font = CTFontCreateWithName(name, 16, NULL);
    CFTypeRef keys[] = { kCTFontAttributeName };
    CFTypeRef values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(font);
    CFRelease(name);
    return attributes;
}

static void fontName(CTRunRef run, char *buffer, size_t size)
{
    CTFontRef font = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
    CFStringRef name = CTFontCopyPostScriptName(font);
    CFStringGetCString(name, buffer, (CFIndex)size, kCFStringEncodingASCII);
    CFRelease(name);
}

typedef struct {
    CFIndex location;
    CFIndex length;
    const char *font;
    CFIndex glyphs;
} ExpectedRun;

static void expectRuns(const char *label, CTLineRef line, const ExpectedRun *expected, CFIndex count)
{
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    if (CFArrayGetCount(runs) != count) {
        fprintf(stderr, "FAIL %s: %ld runs, expected %ld\n", label, (long)CFArrayGetCount(runs), (long)count);
        ++failures;
        return;
    }
    for (CFIndex i = 0; i < count; ++i) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        CFRange range = CTRunGetStringRange(run);
        char name[128];
        fontName(run, name, sizeof(name));
        if (range.location != expected[i].location || range.length != expected[i].length || strcmp(name, expected[i].font)
            || (expected[i].glyphs && CTRunGetGlyphCount(run) != expected[i].glyphs)) {
            fprintf(stderr, "FAIL %s run %ld: %ld+%ld %s %ld glyphs, expected %ld+%ld %s %ld glyphs\n", label, (long)i,
                (long)range.location, (long)range.length, name, (long)CTRunGetGlyphCount(run),
                (long)expected[i].location, (long)expected[i].length, expected[i].font, (long)expected[i].glyphs);
            ++failures;
        }
    }
}

// Same runs, fonts and glyphs as the attributed-string typesetter, which reads no provider.
static void expectNative(const char *label, const UniChar *characters, CFIndex length, CFDictionaryRef attributes)
{
    CFStringRef string = CFStringCreateWithCharacters(NULL, characters, length);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CTLineRef native = CTLineCreateWithAttributedString(attributed);
    Text text = { characters, length, attributes, 0, 0 };
    CTLineRef provided = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    CFArrayRef nativeRuns = CTLineGetGlyphRuns(native);
    CFArrayRef providedRuns = CTLineGetGlyphRuns(provided);
    bool same = CFArrayGetCount(nativeRuns) == CFArrayGetCount(providedRuns);
    for (CFIndex i = 0; same && i < CFArrayGetCount(nativeRuns); ++i) {
        CTRunRef a = (CTRunRef)CFArrayGetValueAtIndex(nativeRuns, i);
        CTRunRef b = (CTRunRef)CFArrayGetValueAtIndex(providedRuns, i);
        char nameA[128], nameB[128];
        fontName(a, nameA, sizeof(nameA));
        fontName(b, nameB, sizeof(nameB));
        CFIndex glyphCount = CTRunGetGlyphCount(a);
        same = !strcmp(nameA, nameB) && glyphCount == CTRunGetGlyphCount(b)
            && CTRunGetStringRange(a).location == CTRunGetStringRange(b).location
            && CTRunGetStringRange(a).length == CTRunGetStringRange(b).length;
        if (same && glyphCount) {
            CGGlyph glyphsA[256], glyphsB[256];
            CFIndex compared = glyphCount < 256 ? glyphCount : 256;
            CTRunGetGlyphs(a, CFRangeMake(0, compared), glyphsA);
            CTRunGetGlyphs(b, CFRangeMake(0, compared), glyphsB);
            same = !memcmp(glyphsA, glyphsB, (size_t)compared * sizeof(CGGlyph));
        }
    }
    if (!same) {
        fprintf(stderr, "FAIL %s: typeset differently from the attributed string\n", label);
        ++failures;
    }
    CFRelease(provided);
    CFRelease(native);
    CFRelease(attributed);
    CFRelease(string);
}

#define COUNT(array) ((CFIndex)(sizeof(array) / sizeof(*(array))))

int main(void)
{
    CFDictionaryRef times = attributesWithFont("Times-Roman");
    CFDictionaryRef geeza = attributesWithFont("GeezaPro");

    const UniChar family[] = { 0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67 };
    const UniChar betweenLetters[] = { 'a', 0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67, 'b' };
    const UniChar rainbowFlag[] = { 0xD83C, 0xDFF3, 0xFE0F, 0x200D, 0xD83C, 0xDF08 };
    const UniChar twoSequences[] = { 0x2764, 0xFE0F, 0x200D, 0xD83D, 0xDD25, 0xD83C, 0xDFF3, 0xFE0F, 0x200D, 0xD83C, 0xDF08 };

    Text text = { family, COUNT(family), times, 0, 0 };
    CTLineRef line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    const ExpectedRun familyRuns[] = { { 0, 8, "AppleColorEmoji", 1 } };
    expectRuns("family", line, familyRuns, COUNT(familyRuns));
    CFRelease(line);

    text = (Text) { betweenLetters, COUNT(betweenLetters), times, 0, 0 };
    line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    const ExpectedRun betweenRuns[] = { { 0, 1, "Times-Roman", 1 }, { 1, 8, "AppleColorEmoji", 1 }, { 9, 1, "Times-Roman", 1 } };
    expectRuns("family between letters", line, betweenRuns, COUNT(betweenRuns));
    CFRelease(line);

    text = (Text) { rainbowFlag, COUNT(rainbowFlag), times, 0, 0 };
    line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    const ExpectedRun rainbowRuns[] = { { 0, 6, "AppleColorEmoji", 1 } };
    expectRuns("rainbow flag", line, rainbowRuns, COUNT(rainbowRuns));
    CFRelease(line);

    text = (Text) { twoSequences, COUNT(twoSequences), times, 0, 0 };
    line = CTLineCreateWithUniCharProvider(provide, NULL, &text);
    const ExpectedRun twoRuns[] = { { 0, 11, "AppleColorEmoji", 0 } };
    expectRuns("adjacent sequences share one block", line, twoRuns, COUNT(twoRuns));
    CFRelease(line);

    short level = 1;
    CFNumberRef levelNumber = CFNumberCreate(NULL, kCFNumberShortType, &level);
    CFTypeRef optionKeys[] = { kCTTypesetterOptionForcedEmbeddingLevel };
    CFTypeRef optionValues[] = { levelNumber };
    CFDictionaryRef rightToLeft = CFDictionaryCreate(NULL, optionKeys, optionValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    text = (Text) { family, COUNT(family), times, 0, 0 };
    CTTypesetterRef typesetter = CTTypesetterCreateWithUniCharProviderAndOptions(provide, dispose, &text, rightToLeft);
    line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
    const ExpectedRun rightToLeftRuns[] = { { 0, 8, "AppleColorEmoji", 0 } };
    expectRuns("family, right to left", line, rightToLeftRuns, COUNT(rightToLeftRuns));
    CFRelease(line);
    CFRelease(typesetter);
    if (text.disposed != text.provided) {
        fprintf(stderr, "FAIL dispose: %d blocks provided, %d disposed\n", text.provided, text.disposed);
        ++failures;
    }

    const UniChar keycaps[] = { '#', 0x20E3, ' ', '1', 0xFE0F, 0x20E3 };
    const UniChar skinTone[] = { 0xD83D, 0xDC4D, 0xD83C, 0xDFFE, ' ', 0xD83C, 0xDDFA, 0xD83C, 0xDDF8 };
    const UniChar arabic[] = { 0x0628, 0x0650, 0x0633, 0x0652, 0x0645, 0x0650, ' ', 0x0627, 0x0644, 0x0644, 0x0651, 0x064E, 0x0647, 0x0650 };
    const UniChar devanagari[] = { 0x0915, 0x094D, 0x0937, 0x093F, ' ', 0x0928, 0x092E, 0x0938, 0x094D, 0x0924, 0x0947 };
    const UniChar latin[] = { 'o', 'f', 'f', 'i', 'c', 'e', ' ', 'a', 0x0301, 0x0302 };
    expectNative("keycaps", keycaps, COUNT(keycaps), times);
    expectNative("skin tone and flag", skinTone, COUNT(skinTone), times);
    expectNative("Arabic in Geeza Pro", arabic, COUNT(arabic), geeza);
    expectNative("Arabic falling back from Times", arabic, COUNT(arabic), times);
    expectNative("Devanagari falling back from Times", devanagari, COUNT(devanagari), times);
    expectNative("Latin", latin, COUNT(latin), times);

    if (failures)
        return 1;
    printf("cluster fallback: all cases match\n");
    return 0;
}
