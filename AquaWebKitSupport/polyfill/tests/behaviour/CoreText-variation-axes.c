// kCTFontVariationAttribute realization (polyfills/c/CoreText.c). 10.9's CoreText discards the whole
// variation dictionary when it names an axis the font has not got, or gives an axis a value outside
// its range; newer CoreText applies the axes it recognizes and clamps each value into range. Every
// WebCore realization asks for wght, wdth and a slope axis at once
// (UnrealizedCoreTextFont::modifyFromContext), and almost no variable font carries all three, so 10.9
// throws the whole request away and renders every variable font at its default instance.
//
// Skia is the variable face this system ships: axes Weight (0.4799 - 3.1999, default 1) and Width
// (0.6199 - 1.2999, default 1). 'a' measures 31.0938 wide at 80pt on the defaults, and the requests
// below are judged by that width through both realization entry points, to within one font unit
// (80/2048 pt): an installed variable face draws from a static cut, whose outlines are whole font units.
//
// 10.9 reports Skia's default instance keyed by axis name ({Weight 1, Width 1}), a form its own
// CTFontCreateWithGraphicsFont cannot read from a descriptor that names the font. CTFontCopyVariation,
// CTFontCopyAttribute and CTFontDescriptorCopyAttribute answer it keyed by axis identifier, as CTFont.h
// documents it, and CTFontCreateWithGraphicsFont realizes such a descriptor.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

// The width of 'a' in the realized font, which is what an applied weight or width moves.
static double inkWidth(CTFontRef font)
{
    const UniChar character = 'a';
    CGGlyph glyph = 0;
    if (!font || !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        return NAN;
    CGRect bounds = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &glyph, NULL, 1);
    return bounds.size.width;
}

static CFDictionaryRef variationRequest(const char (*tags)[5], const double *values, unsigned count)
{
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (unsigned i = 0; i < count; ++i) {
        long long tag = ((long long)(unsigned char)tags[i][0] << 24) | ((unsigned char)tags[i][1] << 16)
            | ((unsigned char)tags[i][2] << 8) | (unsigned char)tags[i][3];
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &tag);
        CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &values[i]);
        CFDictionarySetValue(request, key, value);
        CFRelease(key);
        CFRelease(value);
    }
    return request;
}

static CTFontDescriptorRef modificationDescriptor(CFDictionaryRef request)
{
    const void *keys[] = { kCTFontVariationAttribute };
    const void *values[] = { request };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

// The same request through both entry points WebCore realizes a font from: a copy taken off a font,
// and a descriptor naming the face outright.
static const double oneFontUnit = 80.0 / 2048;

static void measure(const char *face, const char (*tags)[5], const double *values, unsigned count,
                    double expected, const char *what)
{
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, face, kCFStringEncodingUTF8);
    CTFontRef base = CTFontCreateWithName(name, 80, NULL);
    CFDictionaryRef request = variationRequest(tags, values, count);
    CTFontDescriptorRef modification = modificationDescriptor(request);

    CTFontRef copied = CTFontCreateCopyWithAttributes(base, 80, NULL, modification);
    char detail[256];
    snprintf(detail, sizeof detail, "%s, through a copy", what);
    double width = inkWidth(copied);
    if (!(fabs(width - expected) <= oneFontUnit)) {
        printf("FAIL: %s (expected %.4f, got %.4f)\n", detail, expected, width);
        failures++;
    }
    if (copied)
        CFRelease(copied);

    CFMutableDictionaryRef named = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(named, kCTFontNameAttribute, name);
    CFDictionarySetValue(named, kCTFontVariationAttribute, request);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(named);
    CTFontRef realized = CTFontCreateWithFontDescriptor(descriptor, 80, NULL);
    snprintf(detail, sizeof detail, "%s, through a descriptor", what);
    width = inkWidth(realized);
    if (!(fabs(width - expected) <= oneFontUnit)) {
        printf("FAIL: %s (expected %.4f, got %.4f)\n", detail, expected, width);
        failures++;
    }
    if (realized)
        CFRelease(realized);
    CFRelease(descriptor);
    CFRelease(named);
    CFRelease(modification);
    CFRelease(request);
    CFRelease(base);
    CFRelease(name);
}

// A font built on a variation of a graphics font made from data stays whole once that graphics font is
// released; the probe runs under MallocScribble, so a read of the released font data finds no glyph.
static void releasedGraphicsFontVariation(void)
{
    FILE *file = fopen("/Library/Fonts/Skia.ttf", "rb");
    long length = file && !fseek(file, 0, SEEK_END) ? ftell(file) : -1;
    UInt8 *contents = length > 0 && !fseek(file, 0, SEEK_SET) ? (UInt8 *)malloc((size_t)length) : NULL;
    CFDataRef bytes = contents && fread(contents, 1, (size_t)length, file) == (size_t)length
        ? CFDataCreate(kCFAllocatorDefault, contents, length) : NULL;
    free(contents);
    if (file)
        fclose(file);
    CGDataProviderRef fromBytes = bytes ? CGDataProviderCreateWithCFData(bytes) : NULL;
    CGFontRef graphics = fromBytes ? CGFontCreateWithDataProvider(fromBytes) : NULL;
    static const char weight[][5] = { "wght" };
    const double weight700[] = { 1.5453503 };
    CFDictionaryRef boldRequest = variationRequest(weight, weight700, 1);
    CTFontDescriptorRef bold = modificationDescriptor(boldRequest);
    CTFontRef varied = graphics ? CTFontCreateWithGraphicsFont(graphics, 80, NULL, bold) : NULL;
    if (graphics)
        CGFontRelease(graphics);
    if (fromBytes)
        CGDataProviderRelease(fromBytes);
    if (bytes)
        CFRelease(bytes);
    double width = inkWidth(varied);
    if (!(fabs(width - 34.296875) <= 0.001)) {
        printf("FAIL: a font on a variation of a released graphics font measures %.4f, not 34.2969\n", width);
        failures++;
    }
    if (varied)
        CFRelease(varied);
    CFRelease(bold);
    CFRelease(boldRequest);
}

int main(void)
{
    releasedGraphicsFontVariation();
    CTFontRef skia = CTFontCreateWithName(CFSTR("Skia-Regular"), 80, NULL);
    CFArrayRef axes = skia ? CTFontCopyVariationAxes(skia) : NULL;
    check(axes && CFArrayGetCount(axes) == 2, "Skia is installed and reports its two axes");
    if (!axes) {
        printf("### CoreText variation axes: Skia is not installed\n");
        return 1;
    }
    const double defaultWidth = 31.09375;
    if (fabs(inkWidth(skia) - defaultWidth) > 0.001) {
        printf("FAIL: Skia measures %.4f at its default instance, not %.4f\n", inkWidth(skia), defaultWidth);
        failures++;
    }
    CFRelease(axes);
    CFRelease(skia);

    static const char oneAxis[][5] = { "wght" };
    static const char withSlope[][5] = { "wght", "slnt" };
    static const char everything[][5] = { "wght", "wdth", "slnt" };
    static const char slopeOnly[][5] = { "slnt" };
    static const char both[][5] = { "wght", "wdth" };

    // The weight WebCore asks a GX font for at CSS weight 700, denormalizeGXWeight(700).
    const double weight700[] = { 1.5453503 };
    const double weight700WithSlope[] = { 1.5453503, 0 };
    const double weight700Everything[] = { 1.5453503, 1, 0 };
    const double weight700Wider[] = { 1.5453503, 1.2 };
    const double cssScaleWeight[] = { 700 };
    const double belowRange[] = { 0.1 };
    const double slope[] = { 0 };

    measure("Skia-Regular", oneAxis, weight700, 1, 34.296875, "an axis the font has, in range");
    measure("Skia-Regular", withSlope, weight700WithSlope, 2, 34.296875, "an axis the font has not got is dropped");
    measure("Skia-Regular", everything, weight700Everything, 3, 34.296875, "the set WebCore asks for on every realization");
    measure("Skia-Regular", both, weight700Wider, 2, 40.625, "two axes the font has");
    measure("Skia-Regular", oneAxis, cssScaleWeight, 1, 44.1015625, "a value above the axis maximum clamps to it");
    measure("Skia-Regular", oneAxis, belowRange, 1, 28.3203125, "a value below the axis minimum clamps to it");
    measure("Skia-Regular", slopeOnly, slope, 1, defaultWidth, "a request of nothing but an absent axis is the default instance");

    // kCTFontVariationAttribute keys an axis by CFNumber; this OS realizes a string-keyed axis as no axis,
    // so a string-keyed weight beside an absent slope is the default instance.
    {
        CTFontRef base = CTFontCreateWithName(CFSTR("Skia-Regular"), 80, NULL);
        CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &weight700[0]);
        long long slnt = ((long long)'s' << 24) | ('l' << 16) | ('n' << 8) | 't';
        CFNumberRef slopeTag = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &slnt);
        CFNumberRef slopeValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &slope[0]);
        const void *requestKeys[] = { CFSTR("wght"), slopeTag };
        const void *requestValues[] = { value, slopeValue };
        CFDictionaryRef request = CFDictionaryCreate(kCFAllocatorDefault, requestKeys, requestValues, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(slopeTag);
        CFRelease(slopeValue);
        CTFontDescriptorRef modification = modificationDescriptor(request);
        CTFontRef copied = CTFontCreateCopyWithAttributes(base, 80, NULL, modification);
        double width = inkWidth(copied);
        if (fabs(width - defaultWidth) > 0.001) {
            printf("FAIL: a string-keyed request is the default instance (expected %.4f, got %.4f)\n", defaultWidth, width);
            failures++;
        }
        CFRelease(copied);
        CFRelease(modification);
        CFRelease(request);
        CFRelease(value);
        CFRelease(base);
    }

    // A copy taken from an already-varied font with a request that needs rewriting is the copy the
    // equivalent valid request takes.
    {
        const double wider[] = { 1.2, 0 };
        static const char widthAndSlope[][5] = { "wdth", "slnt" };
        static const char widthOnly[][5] = { "wdth" };
        CTFontRef base = CTFontCreateWithName(CFSTR("Skia-Regular"), 80, NULL);
        CFDictionaryRef boldRequest = variationRequest(oneAxis, weight700, 1);
        CTFontDescriptorRef bold = modificationDescriptor(boldRequest);
        CTFontRef varied = CTFontCreateCopyWithAttributes(base, 80, NULL, bold);
        CFDictionaryRef rewrittenRequest = variationRequest(widthAndSlope, wider, 2);
        CFDictionaryRef validRequest = variationRequest(widthOnly, wider, 1);
        CTFontDescriptorRef rewritten = modificationDescriptor(rewrittenRequest);
        CTFontDescriptorRef valid = modificationDescriptor(validRequest);
        CTFontRef fromRewritten = CTFontCreateCopyWithAttributes(varied, 80, NULL, rewritten);
        CTFontRef fromValid = CTFontCreateCopyWithAttributes(varied, 80, NULL, valid);
        CFDictionaryRef rewrittenVariation = CTFontCopyVariation(fromRewritten);
        CFDictionaryRef validVariation = CTFontCopyVariation(fromValid);
        double rewrittenWidth = inkWidth(fromRewritten), validWidth = inkWidth(fromValid);
        if (fabs(rewrittenWidth - validWidth) > 0.001 || fabs(inkWidth(varied) - 34.296875) > 0.001
            || !rewrittenVariation || !validVariation || !CFEqual(rewrittenVariation, validVariation)) {
            printf("FAIL: a copy of a varied font under a rewritten request (%.4f) is the valid request's copy (%.4f)\n",
                rewrittenWidth, validWidth);
            failures++;
        }
        CFTypeRef releases[] = { base, boldRequest, bold, varied, rewrittenRequest, validRequest, rewritten, valid,
            fromRewritten, fromValid, rewrittenVariation, validVariation };
        for (size_t i = 0; i < sizeof releases / sizeof releases[0]; ++i) {
            if (releases[i])
                CFRelease(releases[i]);
        }
    }

    // The default instance's variation, keyed by axis identifier, and the descriptors that name the font
    // realized on its graphics font.
    {
        CTFontRef base = CTFontCreateWithName(CFSTR("Skia-Regular"), 80, NULL);
        CTFontDescriptorRef own = CTFontCopyFontDescriptor(base);
        CTFontDescriptorRef named = CTFontDescriptorCreateWithNameAndSize(CFSTR("Skia-Regular"), 80);
        CFTypeRef answers[] = { CTFontCopyVariation(base), CTFontCopyAttribute(base, kCTFontVariationAttribute),
            CTFontDescriptorCopyAttribute(own, kCTFontVariationAttribute),
            CTFontDescriptorCopyAttribute(named, kCTFontVariationAttribute) };
        static const char *const sources[] = { "CTFontCopyVariation", "CTFontCopyAttribute",
            "CTFontDescriptorCopyAttribute of the font's descriptor", "CTFontDescriptorCopyAttribute of a named descriptor" };
        const double defaults[] = { 1, 1 };
        CFDictionaryRef expected = variationRequest(both, defaults, 2);
        for (size_t i = 0; i < sizeof answers / sizeof answers[0]; ++i) {
            if (!answers[i] || CFGetTypeID(answers[i]) != CFDictionaryGetTypeID() || !CFEqual(answers[i], expected)) {
                printf("FAIL: %s keys Skia's default instance by axis identifier\n", sources[i]);
                failures++;
            }
            if (answers[i])
                CFRelease(answers[i]);
        }
        CGFontRef graphics = CTFontCopyGraphicsFont(base, NULL);
        CTFontRef fromGraphics = CTFontCreateWithGraphicsFont(graphics, 80, NULL, own);
        CTFontRef fromNamed = CTFontCreateWithGraphicsFont(graphics, 80, NULL, named);
        CTFontRef fromDescriptor = CTFontCreateWithFontDescriptor(own, 80, NULL);
        check(fabs(inkWidth(fromGraphics) - defaultWidth) < 0.001,
            "CTFontCreateWithGraphicsFont realizes Skia's own descriptor at the default instance");
        check(fabs(inkWidth(fromNamed) - defaultWidth) < 0.001,
            "CTFontCreateWithGraphicsFont realizes a descriptor naming Skia at the default instance");
        check(fabs(inkWidth(fromDescriptor) - defaultWidth) < 0.001,
            "CTFontCreateWithFontDescriptor realizes Skia's own descriptor at the default instance");
        CFTypeRef releases[] = { base, own, named, expected, graphics, fromGraphics, fromNamed, fromDescriptor };
        for (size_t i = 0; i < sizeof releases / sizeof releases[0]; ++i) {
            if (releases[i])
                CFRelease(releases[i]);
        }
    }

    // A face with no axes at all keeps its own metrics under the same request.
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 80, NULL);
    double plain = inkWidth(helvetica);
    check(!isnan(plain), "Helvetica measures");
    measure("Helvetica", everything, weight700Everything, 3, plain, "a font with no axes is unmoved");
    if (helvetica)
        CFRelease(helvetica);

    if (failures) {
        printf("### CoreText variation axes: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText variation axes: a request realizes the axes the font has, each value clamped\n");
    return 0;
}
