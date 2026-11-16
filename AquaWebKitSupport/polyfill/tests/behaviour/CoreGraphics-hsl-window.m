// Hue, saturation, color and luminosity drawn into a window context, the way a view that is not layer-backed draws, through
// the read-back route (polyfills/c/CoreGraphics.c), against Compositing and Blending Level 1's definition computed here.
// Source and backdrop colours cover every order of the three components, drawn in the window's own colour space. 10.9's
// own composite into the window misses the definition, which is the premise. A blending group covering half its area,
// composited plainly and under hue, leaves the other half's destination as it was, in a titled window, whose backing
// carries alpha, and in a borderless one, whose backing does not. A shadowed draw and a shadowed blending group under
// luminosity match 10.9's own normal draws of the same black shapes, and a conic gradient with hard stops on the quadrant
// boundaries matches the four quadrants filled. Grid colours change from one backing pixel to the next and the cells sit
// off the view's origin, so a composite off by a pixel or by the backing scale shows.
#import <Cocoa/Cocoa.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>

CGImageRef CGWindowContextCreateImage(CGContextRef);
CGColorSpaceRef CGContextGetColorSpace(CGContextRef);
void wk_beginBlendingGroupLayer(CGContextRef);
typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static void *systemSymbol(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

enum { kCount = 18, kPitch = kCount + 2, kShiftX = 3, kShiftY = 5 };
static double gColors[kCount][3];

static void buildColors(void)
{
    const double spreads[2][3] = { { 0.1, 0.45, 0.9 }, { 0.3, 0.55, 0.65 } };
    const int perms[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 }, { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
    int n = 0;
    for (int s = 0; s < 2; s++) {
        for (int p = 0; p < 6; p++, n++) {
            for (int i = 0; i < 3; i++)
                gColors[n][i] = spreads[s][perms[p][i]];
        }
    }
    for (int mask = 1; mask < 7; mask++, n++) {
        for (int i = 0; i < 3; i++)
            gColors[n][i] = (mask >> i) & 1 ? 0.85 : 0.15;
    }
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

static void setSat(double c[3], double s)
{
    int max = 0, min = 0;
    for (int i = 1; i < 3; i++) {
        if (c[i] > c[max])
            max = i;
        if (c[i] < c[min])
            min = i;
    }
    if (c[max] <= c[min]) {
        c[0] = c[1] = c[2] = 0;
        return;
    }
    int mid = 3 - max - min;
    c[mid] = (c[mid] - c[min]) * s / (c[max] - c[min]);
    c[max] = s;
    c[min] = 0;
}

// An opaque source over an opaque backdrop under `mode`.
static void expected(CGBlendMode mode, const double s[3], const double b[3], double out[3])
{
    memcpy(out, mode == kCGBlendModeHue || mode == kCGBlendModeColor ? s : b, 3 * sizeof(double));
    if (mode == kCGBlendModeHue)
        setSat(out, sat(b));
    if (mode == kCGBlendModeSaturation)
        setSat(out, sat(s));
    setLum(out, lum(mode == kCGBlendModeLuminosity ? s : b));
}

// The colour of grid pixel `pixel` along one axis, `density` pixels to a point: pixels within one point differ.
static int gridIndex(int pixel, int density)
{
    return (pixel / density + (pixel % density) * 5) % kCount;
}

static CGImageRef createGrid(CGColorSpaceRef space, int byColumn, int density)
{
    int side = kCount * density;
    uint8_t *pixels = malloc((size_t)side * side * 4);
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            const double *c = gColors[gridIndex(byColumn ? x : y, density)];
            uint8_t *p = pixels + (y * side + x) * 4;
            p[0] = (uint8_t)lround(c[2] * 255);
            p[1] = (uint8_t)lround(c[1] * 255);
            p[2] = (uint8_t)lround(c[0] * 255);
            p[3] = 255;
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, (size_t)side * side * 4, NULL);
    CGImageRef image = CGImageCreate(side, side, 8, 32, side * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

static CGImageRef createBlack(CGColorSpaceRef space)
{
    static uint8_t pixel[4] = { 0, 0, 0, 255 };
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixel, 4, NULL);
    CGImageRef image = CGImageCreate(1, 1, 8, 32, 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL,
        false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

// Fills with an opaque colour of the window's own space.
static void setFill(CGContextRef context, CGColorSpaceRef space, CGFloat red, CGFloat green, CGFloat blue)
{
    const CGFloat components[] = { red, green, blue, 1 };
    CGContextSetFillColorSpace(context, space);
    CGContextSetFillColor(context, components);
}

static const char *gWindowKind = "borderless";
static const CGBlendMode kModes[] = { kCGBlendModeHue, kCGBlendModeSaturation, kCGBlendModeColor, kCGBlendModeLuminosity };
static const char *kNames[] = { "hue", "saturation", "color", "luminosity" };

@interface GridView : NSView
@end

@implementation GridView
- (void)drawRect:(NSRect)rect
{
    (void)rect;
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    CGColorSpaceRef space = CGColorSpaceRetain(CGContextGetColorSpace(context));
    int density = (int)lround(self.window.backingScaleFactor), side = kCount * density;
    CGImageRef backdrop = createGrid(space, 0, density), source = createGrid(space, 1, density), black = createBlack(space);
    DrawImageFn system = (DrawImageFn)systemSymbol("_CGContextDrawImage");
    void (*systemBeginLayer)(CGContextRef, CFDictionaryRef) = systemSymbol("_CGContextBeginTransparencyLayer");
    void (*systemEndLayer)(CGContextRef) = systemSymbol("_CGContextEndTransparencyLayer");
    if (!system || !systemBeginLayer || !systemEndLayer) {
        check(0, "10.9's own CGContextDrawImage and transparency layer entry points resolve");
        exit(1);
    }
    // The scale checks need a backing scale above 1 to see a drawable scale error.
    printf("    %s window backing scale %d\n", gWindowKind, density);
    // Each grid pixel covers one backing pixel.
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextTranslateCTM(context, kShiftX, kShiftY);
    // Row 2: a red cell under a blending group of blue over its left half, composited plainly and then under hue.
    for (int hue = 0; hue < 2; hue++) {
        CGRect cell = CGRectMake(hue * kPitch, 2 * kPitch, kCount, kCount);
        setFill(context, space, 0.9, 0.2, 0.1);
        CGContextFillRect(context, cell);
        CGContextSaveGState(context);
        CGContextSetBlendMode(context, hue ? kCGBlendModeHue : kCGBlendModeNormal);
        wk_beginBlendingGroupLayer(context);
        setFill(context, space, 0.1, 0.2, 0.9);
        CGContextFillRect(context, CGRectMake(cell.origin.x, cell.origin.y, kCount / 2, kCount));
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
    // Row 3: a shadowed black square over white, drawn under luminosity through the route and under normal by 10.9, then
    // the same as a blending group. Luminosity of black over white is black, so each pair matches.
    CGFloat shadowComponents[] = { 0, 0, 0, 0.5 };
    CGColorRef shadow = CGColorCreate(space, shadowComponents);
    for (int group = 0; group < 2; group++) {
        for (int reference = 0; reference < 2; reference++) {
            CGRect cell = CGRectMake((group * 2 + reference) * kPitch, 3 * kPitch, kCount, kCount);
            CGRect square = CGRectMake(cell.origin.x + 4, cell.origin.y + 7, 8, 8);
            setFill(context, space, 1, 1, 1);
            CGContextFillRect(context, cell);
            CGContextSaveGState(context);
            CGContextClipToRect(context, cell);
            CGContextSetShadowWithColor(context, CGSizeMake(3, -3), 0, shadow);
            CGContextSetBlendMode(context, reference ? kCGBlendModeNormal : kCGBlendModeLuminosity);
            if (!group)
                (reference ? system : CGContextDrawImage)(context, square, black);
            else {
                if (reference)
                    systemBeginLayer(context, NULL);
                else
                    wk_beginBlendingGroupLayer(context);
                setFill(context, space, 0, 0, 0);
                CGContextFillRect(context, square);
                (reference ? systemEndLayer : CGContextEndTransparencyLayer)(context);
            }
            CGContextRestoreGState(context);
        }
    }
    CGColorRelease(shadow);
    // Row 4: a conic gradient with hard stops on the quadrant boundaries around a point one backing pixel past the cell's
    // centre, then its quadrants filled.
    static const CGFloat kQuadrants[4][3] = { { 0.9, 0.2, 0.1 }, { 0.1, 0.7, 0.3 }, { 0.1, 0.2, 0.9 }, { 0.9, 0.8, 0.1 } };
    CGFloat stops[8 * 4], locations[8];
    for (int i = 0; i < 8; i++) {
        locations[i] = (i + 1) / 2 / 4.0;
        for (int c = 0; c < 3; c++)
            stops[i * 4 + c] = kQuadrants[i / 2][c];
        stops[i * 4 + 3] = 1;
    }
    CGGradientRef conic = CGGradientCreateWithColorComponents(space, stops, locations, 8);
    CGFloat split = kCount / 2 + 1.0 / density;
    CGPoint center = CGPointMake(split, 4 * kPitch + split);
    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(0, 4 * kPitch, kCount, kCount));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    CGContextDrawConicGradient(context, conic, center, 0);
#pragma clang diagnostic pop
    CGContextRestoreGState(context);
    CGGradientRelease(conic);
    for (int q = 0; q < 4; q++) {
        bool right = q == 0 || q == 3, top = q < 2;
        setFill(context, space, kQuadrants[q][0], kQuadrants[q][1], kQuadrants[q][2]);
        CGContextFillRect(context, CGRectMake(kPitch + (right ? split : 0), 4 * kPitch + (top ? split : 0), right ? kCount - split : split,
            top ? kCount - split : split));
    }
    // Row 0: the route, mode by mode; row 1: 10.9's own definition.
    for (int system10_9 = 0; system10_9 < 2; system10_9++) {
        for (int m = 0; m < 4; m++) {
            CGRect cell = CGRectMake(m * kPitch, system10_9 * kPitch, kCount, kCount);
            CGContextSetBlendMode(context, kCGBlendModeCopy);
            CGContextDrawImage(context, cell, backdrop);
            CGContextSetBlendMode(context, kModes[m]);
            if (system10_9)
                system(context, cell, source);
            else
                CGContextDrawImage(context, cell, source);
        }
    }
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    CGImageRef backing = CGWindowContextCreateImage(context);
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(backing));
    const uint8_t *base = CFDataGetBytePtr(data);
    size_t stride = CGImageGetBytesPerRow(backing), height = CGImageGetHeight(backing);
    // The backing pixel `x` pixels right of and `y` pixels above the bottom left corner of cell (column, row).
#define PIXEL(column, row, x, y) (base + (height - 1 - (size_t)((kShiftY + (row) * kPitch) * density + (y))) * stride \
    + (size_t)((kShiftX + (column) * kPitch) * density + (x)) * 4)
    int systemWorst = 0;
    for (int system10_9 = 0; system10_9 < 2; system10_9++) {
        for (int m = 0; m < 4; m++) {
            int worst = 0;
            for (int y = 0; y < side; y++) {
                for (int x = 0; x < side; x++) {
                    double out[3], source[3], backdrop[3];
                    for (int i = 0; i < 3; i++) {
                        source[i] = round(gColors[gridIndex(x, density)][i] * 255) / 255;
                        backdrop[i] = round(gColors[gridIndex(y, density)][i] * 255) / 255;
                    }
                    expected(kModes[m], source, backdrop, out);
                    // Image row y is the cell's (side - 1 - y)th backing row from the bottom.
                    const uint8_t *p = PIXEL(m, system10_9, x, side - 1 - y);
                    for (int i = 0; i < 3; i++)
                        worst = (int)fmax(worst, fabs(p[2 - i] - out[i] * 255));
                }
            }
            if (system10_9) {
                if (m < 2)
                    systemWorst = (int)fmax(systemWorst, worst);
                continue;
            }
            char what[100];
            snprintf(what, sizeof(what), "%s into a window context: within 1 of the definition (%d)", kNames[m], worst);
            check(worst <= 1, what);
        }
    }
    for (int hue = 0; hue < 2; hue++) {
        double red[3] = { round(0.9 * 255) / 255, round(0.2 * 255) / 255, round(0.1 * 255) / 255 };
        double blue[3] = { round(0.1 * 255) / 255, round(0.2 * 255) / 255, round(0.9 * 255) / 255 };
        double covered[3];
        if (hue)
            expected(kCGBlendModeHue, blue, red, covered);
        else
            memcpy(covered, blue, sizeof(covered));
        int coveredWorst = 0, uncoveredWorst = 0;
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                const uint8_t *p = PIXEL(hue, 2, x, y);
                bool isCovered = x < kCount / 2 * density;
                const double *want = isCovered ? covered : red;
                for (int i = 0; i < 3; i++) {
                    int d = (int)fabs(p[2 - i] - want[i] * 255);
                    if (isCovered)
                        coveredWorst = MAX(coveredWorst, d);
                    else
                        uncoveredWorst = MAX(uncoveredWorst, d);
                }
            }
        }
        char what[120];
        snprintf(what, sizeof(what), "a blending group%s, %s: covered half within 1 of the definition (%d)", hue ? " under hue" : "", gWindowKind, coveredWorst);
        check(coveredWorst <= 1, what);
        snprintf(what, sizeof(what), "a blending group%s, %s: the uncovered half keeps the destination (%d)", hue ? " under hue" : "", gWindowKind, uncoveredWorst);
        check(uncoveredWorst <= 1, what);
    }
    for (int group = 0; group < 2; group++) {
        int worst = 0, shadowed = 0;
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                const uint8_t *route = PIXEL(group * 2, 3, x, y), *reference = PIXEL(group * 2 + 1, 3, x, y);
                shadowed += reference[1] > 64 && reference[1] < 192;
                for (int i = 0; i < 3; i++)
                    worst = MAX(worst, abs(route[i] - reference[i]));
            }
        }
        // The shadow's uncovered part: 64 square points less the 25 the square hides.
        char what[120];
        snprintf(what, sizeof(what), "a shadowed %s under luminosity, %s: within 2 of 10.9's normal draw (%d)", group ? "blending group" : "image",
            gWindowKind, worst);
        check(worst <= 2, what);
        snprintf(what, sizeof(what), "a shadowed %s, %s: 10.9's shadow covers 39 points (%d pixels)", group ? "blending group" : "image", gWindowKind,
            shadowed);
        check(shadowed == 39 * density * density, what);
    }
    int conicWorst = 0;
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            const uint8_t *drawn = PIXEL(0, 4, x, y), *filled = PIXEL(1, 4, x, y);
            for (int i = 0; i < 3; i++)
                conicWorst = MAX(conicWorst, abs(drawn[i] - filled[i]));
        }
    }
    char conicWhat[120];
    snprintf(conicWhat, sizeof(conicWhat), "a hard-stop conic gradient, %s: within 1 of its quadrants filled (%d)", gWindowKind, conicWorst);
    check(conicWorst <= 1, conicWhat);
#undef PIXEL
    printf("    10.9's own hue and saturation into the window: worst %d\n", systemWorst);
    check(systemWorst > 16, "10.9's own hue and saturation miss the definition in a window");
    CFRelease(data);
    CGImageRelease(backing);
    CGImageRelease(backdrop);
    CGImageRelease(source);
    CGImageRelease(black);
    CGColorSpaceRelease(space);
    exit(failures != 0);
}
@end

// The window is borderless, or titled when the argument says so.
int main(int argc, char **argv)
{
    @autoreleasepool {
        buildColors();
        bool titled = argc > 1 && !strcmp(argv[1], "titled");
        gWindowKind = titled ? "titled" : "borderless";
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kShiftX + 4 * kPitch, kShiftY + 5 * kPitch)
            styleMask:titled ? NSTitledWindowMask : NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        GridView *view = [[GridView alloc] initWithFrame:NSMakeRect(0, 0, kShiftX + 4 * kPitch, kShiftY + 5 * kPitch)];
        window.contentView = view;
        [window orderFront:nil];
        [view display];
        [NSApp run];
    }
    return failures != 0;
}
