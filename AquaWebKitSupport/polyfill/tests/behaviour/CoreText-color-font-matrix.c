#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Moving a font transform to the context preserves both glyphs and their positions.
// Each font supplies a color glyph and an outline glyph as an independent native control.
int main(int argc, char **argv)
{
    assert(argc == 3);
    enum { side = 512, bytes = side * side * 4 };
    const CGAffineTransform matrices[] = {
        { 2, 0, 0, 2, 0, 0 }, { .75, 0, 0, 1.5, 0, 0 },
        { 1, 0, .3, 1, 0, 0 }, { 0, 1, -1, 0, 0, 0 }
    };
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    unsigned failures = 0;
    for (unsigned file = 1; file < 3; ++file) {
        CGDataProviderRef provider = CGDataProviderCreateWithFilename(argv[file]);
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        assert(cgFont);
        CTFontRef plain = CTFontCreateWithGraphicsFont(cgFont, 60, NULL, NULL);
        UniChar text[] = { 'A', file == 1 ? 'C' : 'B' };
        CGGlyph glyphs[2];
        assert(CTFontGetGlyphsForCharacters(plain, text, glyphs, 2));
        for (unsigned variant = 0; variant < sizeof(matrices) / sizeof(*matrices); ++variant) {
            CTFontRef transformed = CTFontCreateWithGraphicsFont(cgFont, 60, &matrices[variant], NULL);
            for (unsigned glyph = 0; glyph < 2; ++glyph) {
                unsigned char *pixels[2] = { calloc(1, bytes), calloc(1, bytes) };
                for (unsigned reference = 0; reference < 2; ++reference) {
                    CGContextRef context = CGBitmapContextCreate(pixels[reference], side, side, 8, side * 4,
                        space, kCGImageAlphaPremultipliedLast);
                    assert(context);
                    CGContextTranslateCTM(context, 220, 180);
                    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
                    CGContextSetShouldAntialias(context, false);
                    // Include a nonidentity text matrix to check composition order.
                    CGAffineTransform textMatrix = CGAffineTransformMake(1, .2, 0, 1, 0, 0);
                    CGContextSetTextMatrix(context, reference ? CGAffineTransformIdentity : textMatrix);
                    if (reference)
                        CGContextConcatCTM(context, CGAffineTransformConcat(matrices[variant], textMatrix));
                    CGPoint position = { 20, 30 };
                    CTFontDrawGlyphs(reference ? plain : transformed, &glyphs[glyph], &position, 1, context);
                    CGContextRelease(context);
                }
                unsigned differences = 0, ink = 0;
                for (unsigned i = 0; i < bytes; ++i) {
                    differences += pixels[0][i] != pixels[1][i];
                    ink += pixels[1][i] != 0;
                }
                CGRect bounds, plainBounds;
                CTFontGetBoundingRectsForGlyphs(transformed, kCTFontOrientationHorizontal, &glyphs[glyph], &bounds, 1);
                CTFontGetBoundingRectsForGlyphs(plain, kCTFontOrientationHorizontal, &glyphs[glyph], &plainBounds, 1);
                CGRect expected = CGRectApplyAffineTransform(plainBounds, matrices[variant]);
                bool boundsMatch = fabs(bounds.origin.x - expected.origin.x) < 0.000001
                    && fabs(bounds.origin.y - expected.origin.y) < 0.000001
                    && fabs(bounds.size.width - expected.size.width) < 0.000001
                    && fabs(bounds.size.height - expected.size.height) < 0.000001;
                printf("font%u matrix%u %s differences=%u ink=%u bounds=%s\n", file, variant,
                    glyph ? "outline" : "color", differences, ink, boundsMatch ? "PASS" : "FAIL");
                failures += differences || !ink || !boundsMatch;
                free(pixels[0]);
                free(pixels[1]);
            }
            CFRelease(transformed);
        }
        CFRelease(plain);
        CGFontRelease(cgFont);
        CGDataProviderRelease(provider);
    }
    CGColorSpaceRelease(space);
    return failures ? 1 : 0;
}
