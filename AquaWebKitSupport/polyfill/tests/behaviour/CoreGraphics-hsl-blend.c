// Hue, saturation, color and luminosity through the read-back route (polyfills/c/CoreGraphics.c) into an IOSurface
// context and into bitmap contexts of every 8-bit RGB layout, against Compositing and Blending Level 1's definition
// computed here. Source and backdrop colours cover every order of the three components, ties included, opaque and
// translucent. 10.9's own composite misses the definition for some orders, which is the premise. Inside a transparency
// layer the bitmap's data is not what is drawn into, so a draw there is 10.9's own. A frame-sized hue draw costs no more
// than 10.9's own.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
IOSurfaceRef CGIOSurfaceContextGetSurface(CGContextRef);

typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

// 10.9's definition, reached through dyld's image lookup: dlsym answers registered names with the archive's definition.
static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

// A 10.9 CoreGraphics function by name, as a caller outside WebKit reaches it.
static void *systemFunction(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static double lum(const double c[3]) { return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]; }

static void setLum(double c[3], double l)
{
    double d = l - lum(c);
    for (int i = 0; i < 3; i++)
        c[i] += d;
    double m = lum(c), n = fmin(c[0], fmin(c[1], c[2])), x = fmax(c[0], fmax(c[1], c[2]));
    if (n < 0) {
        for (int i = 0; i < 3; i++)
            c[i] = m + (c[i] - m) * m / (m - n);
    }
    if (x > 1) {
        for (int i = 0; i < 3; i++)
            c[i] = m + (c[i] - m) * (1 - m) / (x - m);
    }
}

static double sat(const double c[3]) { return fmax(c[0], fmax(c[1], c[2])) - fmin(c[0], fmin(c[1], c[2])); }

// The definition's SetSat: the largest component becomes `s`, the smallest 0, the middle one scaled between them.
static void setSat(double c[3], double s)
{
    int order[3] = { 0, 1, 2 };
    for (int i = 0; i < 3; i++) {
        for (int j = i + 1; j < 3; j++) {
            if (c[order[j]] < c[order[i]]) {
                int t = order[i];
                order[i] = order[j];
                order[j] = t;
            }
        }
    }
    double lo = c[order[0]], mid = c[order[1]], hi = c[order[2]];
    double out[3];
    out[order[0]] = 0;
    out[order[1]] = hi > lo ? (mid - lo) * s / (hi - lo) : 0;
    out[order[2]] = hi > lo ? s : 0;
    memcpy(c, out, sizeof(out));
}

// Source over a backdrop, premultiplied 0..1 with alpha last, under `mode`.
static void expected(CGBlendMode mode, const double s[4], const double b[4], double out[4])
{
    double cs[3], cb[3], r[3];
    for (int i = 0; i < 3; i++) {
        cs[i] = s[3] > 0 ? s[i] / s[3] : 0;
        cb[i] = b[3] > 0 ? b[i] / b[3] : 0;
    }
    switch (mode) {
    case kCGBlendModeHue:
        memcpy(r, cs, sizeof(r));
        setSat(r, sat(cb));
        setLum(r, lum(cb));
        break;
    case kCGBlendModeSaturation:
        memcpy(r, cb, sizeof(r));
        setSat(r, sat(cs));
        setLum(r, lum(cb));
        break;
    case kCGBlendModeColor:
        memcpy(r, cs, sizeof(r));
        setLum(r, lum(cb));
        break;
    default:
        memcpy(r, cb, sizeof(r));
        setLum(r, lum(cs));
        break;
    }
    for (int i = 0; i < 3; i++)
        out[i] = s[i] * (1 - b[3]) + b[i] * (1 - s[3]) + s[3] * b[3] * r[i];
    out[3] = s[3] + b[3] - s[3] * b[3];
}

enum { kCount = 39 };
static double gColors[kCount][3];

// Every order of three distinct levels, at two spreads, then every pattern of ties among {0.15, 0.85}, then greys.
static void buildColors(void)
{
    const double spreads[2][3] = { { 0.1, 0.45, 0.9 }, { 0.3, 0.55, 0.65 } };
    const int perms[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 }, { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
    int n = 0;
    for (int s = 0; s < 2; s++) {
        for (int p = 0; p < 6; p++) {
            for (int i = 0; i < 3; i++)
                gColors[n][i] = spreads[s][perms[p][i]];
            n++;
        }
    }
    for (int mask = 0; mask < 8; mask++) {
        for (int i = 0; i < 3; i++)
            gColors[n][i] = (mask >> i) & 1 ? 0.85 : 0.15;
        n++;
    }
    for (int k = 0; k < 6; k++) {
        double v = 0.05 + 0.18 * k;
        for (int p = 0; p < 3; p++) {
            gColors[n][0] = gColors[n][1] = gColors[n][2] = v;
            gColors[n][p] = fmin(v + 0.3, 1);
            n++;
        }
    }
    while (n < kCount) {
        gColors[n][0] = gColors[n][1] = gColors[n][2] = (n % 2) ? 0.0 : 1.0;
        n++;
    }
}

// A kCount x kCount BGRA image: column x holds colour x when `byColumn`, row y holds colour y otherwise, at `alpha`.
static CGImageRef createGrid(CGColorSpaceRef space, int byColumn, double alpha)
{
    uint8_t *pixels = malloc(kCount * kCount * 4);
    for (int y = 0; y < kCount; y++) {
        for (int x = 0; x < kCount; x++) {
            const double *c = gColors[byColumn ? x : y];
            uint8_t *p = pixels + (y * kCount + x) * 4;
            p[0] = (uint8_t)lround(c[2] * alpha * 255);
            p[1] = (uint8_t)lround(c[1] * alpha * 255);
            p[2] = (uint8_t)lround(c[0] * alpha * 255);
            p[3] = (uint8_t)lround(alpha * 255);
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kCount * kCount * 4, NULL);
    CGImageRef image = CGImageCreate(kCount, kCount, 8, 32, kCount * 4, space, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

static CGContextRef createSurfaceContext(CGColorSpaceRef space)
{
    int side = kCount, bytesPerElement = 4;
    unsigned format = 'BGRA';
    CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &side);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    CFNumberRef pixelFormat = CFNumberCreate(NULL, kCFNumberIntType, &format);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    const void *values[] = { size, size, element, pixelFormat };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(size);
    CFRelease(element);
    CFRelease(pixelFormat);
    CGContextRef context = CGIOSurfaceContextCreate(surface, kCount, kCount, 8, 32, space, kBGRA);
    CFRelease(surface);
    return context;
}

// Draws the backdrop grid and then the source grid under `mode` into `context`, and returns the largest difference from
// the definition over every pixel, reading the pixels from `pixels` rows `stride` apart once `context` is flushed.
// Byte offsets of red, green, blue and alpha in a pixel of `layout`, and whether it keeps alpha.
static int layoutOffsets(CGBitmapInfo layout, int offsets[4])
{
    CGImageAlphaInfo alpha = (CGImageAlphaInfo)(layout & kCGBitmapAlphaInfoMask);
    int first = alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaNoneSkipFirst;
    int little = (layout & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
    int order[4] = { first ? 1 : 0, first ? 2 : 1, first ? 3 : 2, first ? 0 : 3 };
    for (int i = 0; i < 4; i++)
        offsets[i] = little ? 3 - order[i] : order[i];
    return alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaPremultipliedLast;
}

static int worstDifference(CGContextRef context, CGBitmapInfo layout, const uint8_t *(^pixels)(size_t *stride), CGBlendMode mode,
    double sourceAlpha, double backdropAlpha, CGColorSpaceRef space, DrawImageFn draw)
{
    int offsets[4];
    int keepsAlpha = layoutOffsets(layout, offsets);
    CGImageRef backdrop = createGrid(space, 0, backdropAlpha), source = createGrid(space, 1, sourceAlpha);
    CGRect all = CGRectMake(0, 0, kCount, kCount);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, all, backdrop);
    CGContextSetBlendMode(context, mode);
    if (draw)
        draw(context, all, source);
    else
        CGContextDrawImage(context, all, source);
    CGContextFlush(context);
    size_t stride = 0;
    const uint8_t *base = pixels(&stride);
    int worst = 0;
    for (int y = 0; y < kCount; y++) {
        for (int x = 0; x < kCount; x++) {
            double s[4], b[4], out[4];
            for (int i = 0; i < 3; i++) {
                s[i] = round(gColors[x][i] * sourceAlpha * 255) / 255;
                b[i] = round(gColors[y][i] * backdropAlpha * 255) / 255;
            }
            s[3] = round(sourceAlpha * 255) / 255;
            b[3] = round(backdropAlpha * 255) / 255;
            expected(mode, s, b, out);
            const uint8_t *p = base + y * stride + x * 4;
            for (int i = 0; i < (keepsAlpha ? 4 : 3); i++)
                worst = (int)fmax(worst, fabs(p[offsets[i]] - out[i] * 255));
        }
    }
    CGImageRelease(source);
    CGImageRelease(backdrop);
    return worst;
}

int main(void)
{
    buildColors();
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    static const struct { CGBlendMode mode; const char *name; } modes[] = {
        { kCGBlendModeHue, "hue" }, { kCGBlendModeSaturation, "saturation" }, { kCGBlendModeColor, "color" }, { kCGBlendModeLuminosity, "luminosity" },
    };
    static const double alphas[][2] = { { 1, 1 }, { 0.6, 1 }, { 1, 0.7 }, { 0.6, 0.7 } };
    int systemWorst = 0;
    for (size_t m = 0; m < sizeof(modes) / sizeof(modes[0]); m++) {
        for (size_t a = 0; a < sizeof(alphas) / sizeof(alphas[0]); a++) {
            CGContextRef surface = createSurfaceContext(sRGB);
            IOSurfaceRef surfaceRef = CGIOSurfaceContextGetSurface(surface);
            uint8_t *surfacePixels = malloc(kCount * kCount * 4);
            int worst = worstDifference(surface, kBGRA, ^const uint8_t *(size_t *stride) {
                IOSurfaceLock(surfaceRef, kIOSurfaceLockReadOnly, NULL);
                const uint8_t *base = IOSurfaceGetBaseAddress(surfaceRef);
                size_t rowBytes = IOSurfaceGetBytesPerRow(surfaceRef);
                for (int row = 0; row < kCount; row++)
                    memcpy(surfacePixels + row * kCount * 4, base + row * rowBytes, kCount * 4);
                IOSurfaceUnlock(surfaceRef, kIOSurfaceLockReadOnly, NULL);
                *stride = kCount * 4;
                return surfacePixels;
            }, modes[m].mode, alphas[a][0], alphas[a][1], sRGB, NULL);
            CGContextRelease(surface);
            free(surfacePixels);

            char what[120];
            snprintf(what, sizeof(what), "%s, source alpha %.1f over backdrop alpha %.1f, surface: within 1 (%d)",
                modes[m].name, alphas[a][0], alphas[a][1], worst);
            check(worst <= 1, what);

            static const struct { CGBitmapInfo layout; const char *name; } layouts[] = {
                { kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, "BGRA" },
                { kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big, "ARGB" },
                { kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, "RGBA" },
                { kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little, "ABGR" },
                { kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, "BGRX" },
                { kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, "RGBX" },
            };
            for (size_t l = 0; l < sizeof(layouts) / sizeof(layouts[0]); l++) {
                int offsets[4];
                if (!layoutOffsets(layouts[l].layout, offsets) && alphas[a][1] < 1)
                    continue;
                for (int system = 0; system < 2; system++) {
                    if (system && l)
                        continue;
                    uint8_t *bitmapPixels = calloc(kCount * kCount, 4);
                    CGContextRef bitmap = CGBitmapContextCreate(bitmapPixels, kCount, kCount, 8, kCount * 4, sRGB, layouts[l].layout);
                    int bitmapWorst = worstDifference(bitmap, layouts[l].layout, ^const uint8_t *(size_t *stride) {
                        *stride = kCount * 4;
                        return bitmapPixels;
                    }, modes[m].mode, alphas[a][0], alphas[a][1], sRGB, system ? systemDrawImage() : NULL);
                    CGContextRelease(bitmap);
                    free(bitmapPixels);
                    if (system) {
                        if (modes[m].mode == kCGBlendModeHue || modes[m].mode == kCGBlendModeSaturation)
                            systemWorst = (int)fmax(systemWorst, bitmapWorst);
                        continue;
                    }
                    snprintf(what, sizeof(what), "%s, source alpha %.1f over backdrop alpha %.1f, %s bitmap: within 1 (%d)",
                        modes[m].name, alphas[a][0], alphas[a][1], layouts[l].name, bitmapWorst);
                    check(bitmapWorst <= 1, what);
                }
            }
        }
    }
    printf("    10.9's own composite into a bitmap, hue and saturation: worst %d\n", systemWorst);
    check(systemWorst > 16, "10.9's own hue and saturation miss the definition for some orders");

    // A hue draw inside a transparency layer another caller opened on a bitmap: the bitmap's data holds the backdrop until
    // the layer ends, and the result is 10.9's own.
    {
        DrawImageFn system = systemDrawImage();
        void (*beginLayer)(CGContextRef, CFDictionaryRef) = (void (*)(CGContextRef, CFDictionaryRef))systemFunction("_CGContextBeginTransparencyLayer");
        void (*endLayer)(CGContextRef) = (void (*)(CGContextRef))systemFunction("_CGContextEndTransparencyLayer");
        CGImageRef backdrop = createGrid(sRGB, 0, 1), source = createGrid(sRGB, 1, 1);
        CGRect all = CGRectMake(0, 0, kCount, kCount);
        uint8_t *ours = calloc(kCount * kCount, 4), *stock = calloc(kCount * kCount, 4), *before = malloc(kCount * kCount * 4);
        CGContextRef oursContext = CGBitmapContextCreate(ours, kCount, kCount, 8, kCount * 4, sRGB, kBGRA);
        CGContextRef stockContext = CGBitmapContextCreate(stock, kCount, kCount, 8, kCount * 4, sRGB, kBGRA);
        CGContextDrawImage(oursContext, all, backdrop);
        CGContextDrawImage(stockContext, all, backdrop);
        memcpy(before, ours, kCount * kCount * 4);
        beginLayer(oursContext, NULL);
        CGContextSetBlendMode(oursContext, kCGBlendModeHue);
        CGContextDrawImage(oursContext, all, source);
        int untouched = !memcmp(before, ours, kCount * kCount * 4);
        endLayer(oursContext);
        beginLayer(stockContext, NULL);
        CGContextSetBlendMode(stockContext, kCGBlendModeHue);
        system(stockContext, all, source);
        endLayer(stockContext);
        check(untouched, "inside a transparency layer the bitmap's data holds the backdrop until the layer ends");
        check(!memcmp(ours, stock, kCount * kCount * 4), "a hue draw inside a transparency layer on a bitmap is 10.9's own");
        CGContextRelease(oursContext);
        CGContextRelease(stockContext);
        free(ours);
        free(stock);
        free(before);
        CGImageRelease(backdrop);
        CGImageRelease(source);
    }

    // A frame-sized hue draw, against 10.9's own: the best of three after a warm-up.
    {
        DrawImageFn system = systemDrawImage();
        const int width = 1920, height = 1080;
        uint8_t *pixels = malloc((size_t)width * height * 4);
        srand(3);
        for (size_t i = 0; i < (size_t)width * height; i++) {
            unsigned alpha = 128 + rand() % 128;
            pixels[i * 4 + 3] = alpha;
            for (int k = 0; k < 3; k++)
                pixels[i * 4 + k] = rand() % (alpha + 1);
        }
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, (size_t)width * height * 4, NULL);
        CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, sRGB, kBGRA, provider, NULL, false, kCGRenderingIntentDefault);
        double best[2] = { INFINITY, INFINITY };
        for (int run = 0; run < 4; run++) {
            for (int which = 0; which < 2; which++) {
                CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, sRGB, kBGRA);
                CGContextSetRGBFillColor(context, 0.3, 0.6, 0.4, 1);
                CGContextFillRect(context, CGRectMake(0, 0, width, height));
                CGContextSetBlendMode(context, kCGBlendModeHue);
                uint64_t start = mach_absolute_time();
                if (which)
                    system(context, CGRectMake(0, 0, width, height), image);
                else
                    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
                uint64_t elapsed = mach_absolute_time() - start;
                mach_timebase_info_data_t timebase;
                mach_timebase_info(&timebase);
                double milliseconds = elapsed * (double)timebase.numer / timebase.denom / 1e6;
                if (run)
                    best[which] = fmin(best[which], milliseconds);
                CGContextRelease(context);
            }
        }
        printf("    1920x1080 hue draw: %.1f ms, 10.9's own %.1f ms\n", best[0], best[1]);
        check(best[0] <= best[1] * 1.25, "a frame-sized hue draw costs no more than 10.9's own");
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        free(pixels);
    }
    CGColorSpaceRelease(sRGB);
    return failures != 0;
}
