// The two-pass AAT dispatcher in wk_ots_sanitize_font (polyfills/c/ots_font_parser.cpp), end to end.
// A downloadable font's AAT tables are passed through a first OTS pass, validated against the sanitized
// sfnt, and only the ones that validate are kept; the rest are dropped alone. This asserts, on real
// fonts handed in by path:
//   - a sound morx font keeps its morx (and feat) and shapes identically to the raw bytes, since a kept
//     table is passed through byte for byte;
//   - a sound mort font keeps its mort and shapes identically to the raw bytes;
//   - a font whose morx is structurally out of bounds drops morx ALONE and keeps the rest;
//   - a font whose mort has a state-machine class array running past the table (a 10.9 FetchClass
//     out-of-bounds read) drops mort ALONE and keeps the rest.
// Args: <a morx font, e.g. /Library/Fonts/AlBayan.ttf> <a mort-ligature font that OTS accepts, e.g.
// /Library/Fonts/Apple Chancery.ttf; a font OTS refuses, like Osaka, would fail the "accepted" check>.
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern CFDataRef wk_ots_sanitize_font(CFDataRef data);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static CFDataRef readFile(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *b = malloc(n > 0 ? n : 1);
    size_t got = fread(b, 1, n, f);
    fclose(f);
    CFDataRef d = (got == (size_t)n) ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)b, n) : NULL;
    free(b);
    return d;
}

static int hasTable(CFDataRef font, const char *tag)
{
    if (!font)
        return 0;
    const UInt8 *p = CFDataGetBytePtr(font);
    CFIndex n = CFDataGetLength(font);
    if (n < 12)
        return 0;
    unsigned tables = (p[4] << 8) | p[5];
    if (12 + (CFIndex)tables * 16 > n)
        return 0;
    for (unsigned i = 0; i < tables; ++i)
        if (!memcmp(p + 12 + i * 16, tag, 4))
            return 1;
    return 0;
}

static size_t tableOffset(CFDataRef font, const char *tag)
{
    const UInt8 *p = CFDataGetBytePtr(font);
    unsigned tables = (p[4] << 8) | p[5];
    for (unsigned i = 0; i < tables; ++i)
        if (!memcmp(p + 12 + i * 16, tag, 4))
            return ((size_t)p[12 + i * 16 + 8] << 24) | (p[12 + i * 16 + 9] << 16)
                | (p[12 + i * 16 + 10] << 8) | p[12 + i * 16 + 11];
    return 0;
}

// A font realized the way a downloadable font is: through CGFont, then CoreText.
static CTFontRef realize(CFDataRef sfnt)
{
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(sfnt);
    CGFontRef cg = provider ? CGFontCreateWithDataProvider(provider) : NULL;
    if (provider)
        CGDataProviderRelease(provider);
    if (!cg)
        return NULL;
    CTFontRef ct = CTFontCreateWithGraphicsFont(cg, 24, NULL, NULL);
    CGFontRelease(cg);
    return ct;
}

// The glyph run a font shapes for a string, as a printable digest.
static CFStringRef shapeDigest(CFDataRef sfnt, CFStringRef text)
{
    CTFontRef font = realize(sfnt);
    if (!font)
        return NULL;
    const void *keys[] = { kCTFontAttributeName };
    const void *vals[] = { font };
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(kCFAllocatorDefault, text, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFMutableStringRef digest = CFStringCreateMutable(kCFAllocatorDefault, 0);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex gc = CTRunGetGlyphCount(run);
        CGGlyph *g = (CGGlyph *)malloc(sizeof(CGGlyph) * (gc ? gc : 1));
        CTRunGetGlyphs(run, CFRangeMake(0, gc), g);
        for (CFIndex i = 0; i < gc; ++i)
            CFStringAppendFormat(digest, NULL, CFSTR("%u,"), g[i]);
        free(g);
    }
    CFRelease(line);
    CFRelease(as);
    CFRelease(attrs);
    CFRelease(font);
    return digest;
}

static void expectShapeIdentical(CFDataRef raw, CFDataRef sanitized, const char *text, const char *what)
{
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    CFStringRef a = shapeDigest(raw, s);
    CFStringRef b = shapeDigest(sanitized, s);
    check(a && b && CFStringGetLength(a) > 0 && CFStringCompare(a, b, 0) == kCFCompareEqualTo, what);
    if (a) CFRelease(a);
    if (b) CFRelease(b);
    CFRelease(s);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        printf("usage: %s <morx-font> <mort-font>\n", argv[0]);
        return 2;
    }

    // A sound morx font: morx and feat kept, shaping unchanged.
    CFDataRef morxRaw = readFile(argv[1]);
    check(morxRaw && hasTable(morxRaw, "morx"), "morx fixture loads and carries morx");
    CFDataRef morxSan = morxRaw ? wk_ots_sanitize_font(morxRaw) : NULL;
    check(morxSan != NULL, "the morx font is accepted");
    check(morxSan && hasTable(morxSan, "morx"), "morx is kept");
    check(morxSan && hasTable(morxSan, "feat"), "feat is kept");
    if (morxRaw && morxSan)
        expectShapeIdentical(morxRaw, morxSan, "\xd8\xa7\xd9\x84\xd8\xb9\xd8\xb1\xd8\xa8\xd9\x8a\xd8\xa9", "the morx font shapes identically to the raw bytes");

    // A sound mort font: mort kept, shaping unchanged.
    CFDataRef mortRaw = readFile(argv[2]);
    check(mortRaw && hasTable(mortRaw, "mort"), "mort fixture loads and carries mort");
    CFDataRef mortSan = mortRaw ? wk_ots_sanitize_font(mortRaw) : NULL;
    check(mortSan != NULL, "the mort font is accepted");
    check(mortSan && hasTable(mortSan, "mort"), "mort is kept");
    if (mortRaw && mortSan)
        expectShapeIdentical(mortRaw, mortSan, "\xe3\x81\x82\xe3\x81\x8c\xe3\x81\x82", "the mort font shapes identically to the raw bytes");

    // A mort whose first state-machine subtable's class array runs past the table: 10.9's FetchClass
    // would read out of bounds, so the validator declines the mort while OTS keeps every other table.
    // mort: u32 version, u32 nChains; chain0 at +8 = {u32 defaultFlags, u32 chainLength, u16
    // nFeatureEntries, u16 nSubtables}; feature entries are 12 bytes; a subtable is {u16 length, u16
    // coverage, u32 subFeatureFlags} then its body; a state-machine body starts {u16 stateSize, u16
    // classTableOffset, ...}, and the class table is {u16 firstGlyph, u16 nGlyphs, u8[nGlyphs]}. Blow up
    // nGlyphs of the first state-machine subtable so class + 4 + nGlyphs leaves the table.
    if (mortRaw) {
        CFMutableDataRef corrupt = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, mortRaw);
        size_t mo = tableOffset(corrupt, "mort");
        UInt8 *b = CFDataGetMutableBytePtr(corrupt);
        size_t cursor = mo + 8;
        size_t nFeat = ((size_t)b[cursor + 8] << 8) | b[cursor + 9];       // u16 nFeatureEntries
        size_t nsub = ((size_t)b[cursor + 10] << 8) | b[cursor + 11];      // u16 nSubtables
        size_t sub = cursor + 12 + nFeat * 12;
        int corrupted = 0;
        for (size_t s = 0; s < nsub && !corrupted; ++s) {
            size_t slen = ((size_t)b[sub] << 8) | b[sub + 1];
            unsigned kind = b[sub + 3] & 0x7;                              // coverage low 3 bits
            if (kind == 0 || kind == 1 || kind == 2 || kind == 5) {
                size_t body = sub + 8;
                size_t classOff = ((size_t)b[body + 2] << 8) | b[body + 3];
                size_t classTab = body + classOff;
                b[classTab + 2] = 0xFF; b[classTab + 3] = 0xFF;            // nGlyphs = 0xFFFF
                corrupted = 1;
            }
            sub += slen;
        }
        check(corrupted, "the mort fixture has a state-machine subtable to corrupt");
        CFDataRef san = wk_ots_sanitize_font(corrupt);
        check(san != NULL, "the font with an overrunning mort class array is still accepted");
        check(san && !hasTable(san, "mort"), "the overrunning mort is dropped");
        check(san && (hasTable(san, "glyf") || hasTable(san, "CFF ")), "the outline table is kept when mort is dropped");
        if (san) CFRelease(san);
        CFRelease(corrupt);
    }

    // A morx that would drive unbounded work is dropped alone, the rest of the font kept. The first
    // state-machine subtable's nClasses is set past the work cap; the validator declines the morx while
    // OTS keeps every other table. (A merely truncated chain is not enough: this OS stops at a short
    // chain and shapes what fits, so the validator keeps it -- that is a "still accepted" case, not a
    // drop.)
    if (morxRaw) {
        CFMutableDataRef corrupt = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, morxRaw);
        size_t mo = tableOffset(corrupt, "morx");
        UInt8 *b = CFDataGetMutableBytePtr(corrupt);
        // morx: u16 version, u16 unused, u32 nChains; chain0 at mo+8 = {u32 defaultFlags, u32
        // chainLength, u32 nFeatureEntries, u32 nSubtables}; feature entries are 12 bytes each; a
        // subtable is {u32 length, u32 coverage, u32 subFeatureFlags} then its body. Find the first
        // subtable whose kind (coverage low byte) is a state machine and blow up its nClasses (body+0).
        size_t nFeat = ((size_t)b[mo + 16] << 24) | (b[mo + 17] << 16) | (b[mo + 18] << 8) | b[mo + 19];
        size_t nSub = ((size_t)b[mo + 20] << 24) | (b[mo + 21] << 16) | (b[mo + 22] << 8) | b[mo + 23];
        size_t sub = mo + 24 + nFeat * 12;
        int corrupted = 0;
        for (size_t s = 0; s < nSub && !corrupted; ++s) {
            size_t slen = ((size_t)b[sub] << 24) | (b[sub + 1] << 16) | (b[sub + 2] << 8) | b[sub + 3];
            unsigned kind = b[sub + 11];
            if (kind == 0 || kind == 1 || kind == 2 || kind == 5) {
                size_t body = sub + 12;
                b[body] = 0xff; b[body + 1] = 0xff; b[body + 2] = 0xff; b[body + 3] = 0xff;
                corrupted = 1;
            }
            sub += slen;
        }
        check(corrupted, "the morx fixture has a state-machine subtable to corrupt");
        CFDataRef san = wk_ots_sanitize_font(corrupt);
        check(san != NULL, "the font with an unbounded morx is still accepted");
        check(san && !hasTable(san, "morx"), "the unbounded morx is dropped");
        check(san && hasTable(san, "feat"), "feat is kept when morx is dropped");
        check(san && (hasTable(san, "glyf") || hasTable(san, "CFF ")), "the outline table is kept when morx is dropped");
        if (san) CFRelease(san);
        CFRelease(corrupt);
    }

    if (morxRaw) CFRelease(morxRaw);
    if (morxSan) CFRelease(morxSan);
    if (mortRaw) CFRelease(mortRaw);
    if (mortSan) CFRelease(mortSan);

    if (failures) {
        printf("CoreText-aat-dispatch: %d FAILED\n", failures);
        return 1;
    }
    printf("CoreText-aat-dispatch: ok\n");
    return 0;
}
