// Hue, saturation, color and luminosity drawn into a window context, the way a view that is not layer-backed draws, through
// the read-back route (polyfills/c/CoreGraphics.c), against Compositing and Blending Level 1's definition computed here.
// Source and backdrop colours cover every order of the three components, drawn in the window's own colour space. 10.9's
// own composite into the window misses the definition, which is the premise. A blending group covering half its area,
// composited plainly and under hue, leaves the other half's destination as it was, in a titled window, whose backing
// carries alpha, and in a borderless one, whose backing does not.
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

static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

enum { kCount = 18 };
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

static CGImageRef createGrid(CGColorSpaceRef space, int byColumn)
{
    uint8_t *pixels = malloc(kCount * kCount * 4);
    for (int y = 0; y < kCount; y++) {
        for (int x = 0; x < kCount; x++) {
            const double *c = gColors[byColumn ? x : y];
            uint8_t *p = pixels + (y * kCount + x) * 4;
            p[0] = (uint8_t)lround(c[2] * 255);
            p[1] = (uint8_t)lround(c[1] * 255);
            p[2] = (uint8_t)lround(c[0] * 255);
            p[3] = 255;
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, kCount * kCount * 4, NULL);
    CGImageRef image = CGImageCreate(kCount, kCount, 8, 32, kCount * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
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
    CGImageRef backdrop = createGrid(space, 0), source = createGrid(space, 1);
    DrawImageFn system = systemDrawImage();
    // Row 2: a red cell under a blending group of blue over its left half, composited plainly and then under hue.
    for (int hue = 0; hue < 2; hue++) {
        CGRect cell = CGRectMake(hue * (kCount + 2), 2 * (kCount + 2), kCount, kCount);
        CGContextSetRGBFillColor(context, 0.9, 0.2, 0.1, 1);
        CGContextFillRect(context, cell);
        CGContextSaveGState(context);
        CGContextSetBlendMode(context, hue ? kCGBlendModeHue : kCGBlendModeNormal);
        wk_beginBlendingGroupLayer(context);
        CGContextSetRGBFillColor(context, 0.1, 0.2, 0.9, 1);
        CGContextFillRect(context, CGRectMake(cell.origin.x, cell.origin.y, kCount / 2, kCount));
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
    // Row 0: the route, mode by mode; row 1: 10.9's own definition.
    for (int system10_9 = 0; system10_9 < 2; system10_9++) {
        for (int m = 0; m < 4; m++) {
            CGRect cell = CGRectMake(m * (kCount + 2), system10_9 * (kCount + 2), kCount, kCount);
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
    CGFloat scale = self.window.backingScaleFactor;
    int systemWorst = 0;
    for (int system10_9 = 0; system10_9 < 2; system10_9++) {
        for (int m = 0; m < 4; m++) {
            int worst = 0;
            for (int y = 0; y < kCount; y++) {
                for (int x = 0; x < kCount; x++) {
                    double out[3], source[3], backdrop[3];
                    for (int i = 0; i < 3; i++) {
                        source[i] = round(gColors[x][i] * 255) / 255;
                        backdrop[i] = round(gColors[y][i] * 255) / 255;
                    }
                    expected(kModes[m], source, backdrop, out);
                    size_t column = (size_t)((m * (kCount + 2) + x + 0.5) * scale);
                    size_t row = height - 1 - (size_t)((system10_9 * (kCount + 2) + (kCount - 1 - y) + 0.5) * scale);
                    const uint8_t *p = base + row * stride + column * 4;
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
        for (int y = 0; y < kCount; y++) {
            for (int x = 0; x < kCount; x++) {
                size_t column = (size_t)((hue * (kCount + 2) + x + 0.5) * scale);
                size_t row = height - 1 - (size_t)((2 * (kCount + 2) + y + 0.5) * scale);
                const uint8_t *p = base + row * stride + column * 4;
                const double *want = x < kCount / 2 ? covered : red;
                for (int i = 0; i < 3; i++) {
                    int d = (int)fabs(p[2 - i] - want[i] * 255);
                    if (x < kCount / 2)
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
    printf("    10.9's own hue and saturation into the window: worst %d\n", systemWorst);
    check(systemWorst > 16, "10.9's own hue and saturation miss the definition in a window");
    CFRelease(data);
    CGImageRelease(backing);
    CGImageRelease(backdrop);
    CGImageRelease(source);
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
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, 4 * (kCount + 2), 3 * (kCount + 2))
            styleMask:titled ? NSTitledWindowMask : NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        GridView *view = [[GridView alloc] initWithFrame:NSMakeRect(0, 0, 4 * (kCount + 2), 3 * (kCount + 2))];
        window.contentView = view;
        [window orderFront:nil];
        [view display];
        [NSApp run];
    }
    return failures != 0;
}
