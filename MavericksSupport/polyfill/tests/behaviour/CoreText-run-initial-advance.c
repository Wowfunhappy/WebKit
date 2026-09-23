#include <CoreText/CoreText.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

extern CGSize CTRunGetInitialAdvance(CTRunRef);
static CGSize (*nativeInitial)(CTRunRef);
static int failures;

static void check(bool value, const char *message)
{
    if (!value) {
        fprintf(stderr, "FAIL %s\n", message);
        ++failures;
    }
}

static bool equal(CGSize a, CGSize b)
{
    return fabs(a.width - b.width) < 0.000001 && fabs(a.height - b.height) < 0.000001;
}

static CTLineRef makeLine(CFStringRef text, CGAffineTransform *matrix, bool vertical, bool hanging)
{
    CTFontRef font = CTFontCreateWithName(CFSTR("TimesNewRomanPSMT"), 16, matrix);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontAttributeName, font);
    if (vertical)
        CFDictionarySetValue(attributes, kCTVerticalFormsAttributeName, kCFBooleanTrue);
    CTParagraphStyleRef style = NULL;
    if (hanging) {
        CTLineBoundsOptions bounds = kCTLineBoundsUseHangingPunctuation;
        CTParagraphStyleSetting setting = { kCTParagraphStyleSpecifierLineBoundsOptions, sizeof(bounds), &bounds };
        style = CTParagraphStyleCreate(&setting, 1);
        CFDictionarySetValue(attributes, kCTParagraphStyleAttributeName, style);
    }
    CFAttributedStringRef string = CFAttributedStringCreate(NULL, text, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CFRelease(string);
    if (style)
        CFRelease(style);
    CFRelease(attributes);
    CFRelease(font);
    return line;
}

static void checkReconstruction(CTLineRef line, const char *name)
{
    double reconstructed = 0;
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex i = 0; i < CFArrayGetCount(runs); ++i) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        CGSize initial = CTRunGetInitialAdvance(run);
        reconstructed += initial.width;
        CFIndex count = CTRunGetGlyphCount(run);
        CGSize *advances = malloc((count ? count : 1) * sizeof(CGSize));
        CTRunGetAdvances(run, CFRangeMake(0, 0), advances);
        for (CFIndex j = 0; j < count; ++j)
            reconstructed += advances[j].width;
        free(advances);
        CTRunRef retained = (CTRunRef)CFRetain(run);
        for (unsigned repeat = 0; repeat < 3; ++repeat) {
            CTLineGetGlyphRuns(line);
            check(equal(initial, CTRunGetInitialAdvance(retained)), "repeated capture does not add the line advance twice");
        }
        CFRelease(retained);
    }
    double expected = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    printf("%s reconstructed %.9f native line %.9f\n", name, reconstructed, expected);
    check(fabs(reconstructed - expected) < 0.000001, "glyph advances reconstruct the native line width");
}

static void checkUnchanged(CFStringRef text, CGAffineTransform *matrix, bool vertical, bool hanging)
{
    CTLineRef line = makeLine(text, matrix, vertical, hanging);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex i = 0; i < CFArrayGetCount(runs); ++i) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        check(equal(CTRunGetInitialAdvance(run), nativeInitial(run)), "run-owned positioning and hanging punctuation retain native advances");
    }
    CFRelease(line);
}

static void checkCopies(void)
{
    CTLineRef original = makeLine(CFSTR("#\u20e3AB"), NULL, false, false);
    CTLineRef noOp = CTLineCreateTruncatedLine(original, 1000, kCTLineTruncationEnd, NULL);
    CFArrayRef originalRuns = CTLineGetGlyphRuns(original);
    CTRunRef retained = (CTRunRef)CFRetain(CFArrayGetValueAtIndex(originalRuns, 0));
    CGSize before = CTRunGetInitialAdvance(retained);
    check(before.width > 0, "keycap supplies a nonzero initial advance");
    CFRelease(original);
    check(equal(before, CTRunGetInitialAdvance(retained)), "retained run preserves its initial advance after line release");
    checkReconstruction(noOp, "no-op truncation after original release");
    CTLineRef justified = CTLineCreateJustifiedLine(noOp, 1, 100);
    CTLineRef truncated = CTLineCreateTruncatedLine(noOp, 25, kCTLineTruncationEnd, NULL);
    check(justified && truncated, "justification and truncation produce lines");
    if (justified) {
        checkReconstruction(justified, "justified copy");
        CFRelease(justified);
    }
    if (truncated) {
        checkReconstruction(truncated, "truncated copy");
        CFRelease(truncated);
    }
    CFRelease(noOp);
    check(equal(before, CTRunGetInitialAdvance(retained)), "shared copy release preserves the retained run's advance");
    CFRelease(retained);
}

int main(void)
{
    void *coreText = dlopen("/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText", RTLD_LAZY);
    nativeInitial = (CGSize (*)(CTRunRef))dlsym(coreText, "CTRunGetInitialAdvance");
    check(nativeInitial != NULL, "native initial-advance entry point exists");
    if (!nativeInitial)
        return 1;
    const CFStringRef texts[] = { CFSTR("#\u20e3"), CFSTR("#\u20e3A"), CFSTR("A#\u20e3B"), CFSTR("\u0301A"), CFSTR("#\u20e3\u05d0\u05d1"), CFSTR("\u05d0\u05d1#\u20e3"), CFSTR("\u062d\u064a\u0627\u0629\u064d"), CFSTR("abc") };
    CGAffineTransform scale = CGAffineTransformMakeScale(2, 2);
    for (unsigned i = 0; i < sizeof(texts) / sizeof(*texts); ++i) {
        CTLineRef line = makeLine(texts[i], NULL, false, false);
        checkReconstruction(line, "horizontal line");
        CFRelease(line);
        line = makeLine(texts[i], &scale, false, false);
        checkReconstruction(line, "scaled line");
        CFRelease(line);
    }
    CGAffineTransform rotation = CGAffineTransformMakeRotation(0.3);
    checkUnchanged(CFSTR("\u062d\u064a\u0627\u0629\u064d"), &rotation, false, false);
    checkUnchanged(CFSTR("\u062d\u064a\u0627\u0629\u064d"), NULL, true, false);
    checkUnchanged(CFSTR("#\u20e3A"), NULL, true, false);
    checkUnchanged(CFSTR("\u201cABC"), NULL, false, true);
    checkCopies();
    check(equal(CTRunGetInitialAdvance(NULL), nativeInitial(NULL)), "nil run preserves native result");
    dlclose(coreText);
    if (failures)
        return 1;
    puts("PASS native line reconstruction, retained runs, copies, RTL, transforms and vertical positioning");
    return 0;
}
