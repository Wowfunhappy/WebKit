// fringe <capture.png> < regions : judges each "name expectation x y width height" line (viewport
// coordinates) of a screen capture holding page.html. The page's magenta marker gives the viewport's
// origin on screen. In each region the background is the most common colour and the ink the luminance
// farthest from it; an edge pixel lies strictly between the two, and it is a strong fringe when its RGB
// channel spread exceeds the background's own by more than 30. Subpixel (LCD) smoothing fringes most edge
// pixels and grayscale smoothing none.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const double minimumSubpixel = 50.0;
static const double maximumGrayscale = 5.0;
static const long minimumEdges = 400;

static unsigned char *pixels;
static size_t imageWidth, imageHeight;

static unsigned char *pixel(long x, long y) { return pixels + ((size_t)y * imageWidth + (size_t)x) * 4; }
static int luminance(const unsigned char *p) { return (p[0] + p[1] + p[2]) / 3; }
static int spread(const unsigned char *p)
{
    int high = p[0] > p[1] ? (p[0] > p[2] ? p[0] : p[2]) : (p[1] > p[2] ? p[1] : p[2]);
    int low = p[0] < p[1] ? (p[0] < p[2] ? p[0] : p[2]) : (p[1] < p[2] ? p[1] : p[2]);
    return high - low;
}

static double strongFringe(long x0, long y0, long width, long height, long *edges)
{
    static int histogram[1 << 15];
    memset(histogram, 0, sizeof histogram);
    long x1 = x0 + width < (long)imageWidth ? x0 + width : (long)imageWidth;
    long y1 = y0 + height < (long)imageHeight ? y0 + height : (long)imageHeight;
    for (long y = y0; y < y1; ++y) {
        for (long x = x0; x < x1; ++x) {
            unsigned char *p = pixel(x, y);
            histogram[((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3)]++;
        }
    }
    int mode = 0;
    for (int i = 1; i < (1 << 15); ++i) {
        if (histogram[i] > histogram[mode])
            mode = i;
    }
    unsigned char background[3] = { (unsigned char)(((mode >> 10) & 31) * 8 + 4), (unsigned char)(((mode >> 5) & 31) * 8 + 4), (unsigned char)((mode & 31) * 8 + 4) };
    int backgroundLuminance = luminance(background), backgroundSpread = spread(background), ink = backgroundLuminance;
    for (long y = y0; y < y1; ++y) {
        for (long x = x0; x < x1; ++x) {
            int l = luminance(pixel(x, y));
            if (abs(l - backgroundLuminance) > abs(ink - backgroundLuminance))
                ink = l;
        }
    }
    int low = backgroundLuminance < ink ? backgroundLuminance : ink, high = backgroundLuminance < ink ? ink : backgroundLuminance;
    long fringes = 0;
    *edges = 0;
    for (long y = y0; y < y1; ++y) {
        for (long x = x0; x < x1; ++x) {
            unsigned char *p = pixel(x, y);
            int l = luminance(p);
            if (l <= low + 15 || l >= high - 15)
                continue;
            ++*edges;
            if (spread(p) > 30 + backgroundSpread)
                ++fringes;
        }
    }
    return *edges ? 100.0 * fringes / *edges : 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: fringe capture.png < regions\n");
        return 2;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithFilename(argv[1]);
    CGImageRef image = provider ? CGImageCreateWithPNGDataProvider(provider, NULL, false, kCGRenderingIntentDefault) : NULL;
    if (!image) {
        fprintf(stderr, "fringe: cannot read %s\n", argv[1]);
        return 2;
    }
    imageWidth = CGImageGetWidth(image);
    imageHeight = CGImageGetHeight(image);
    pixels = calloc(imageWidth * imageHeight, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, imageWidth, imageHeight, 8, imageWidth * 4, colorSpace, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, imageWidth, imageHeight), image);

    long originX = -1, originY = -1;
    for (long y = 0; y < (long)imageHeight && originX < 0; ++y) {
        for (long x = 0; x + 11 < (long)imageWidth; ++x) {
            unsigned char *p = pixel(x, y), *q = pixel(x + 11, y);
            if (p[0] > 230 && p[1] < 40 && p[2] > 230 && q[0] > 230 && q[1] < 40 && q[2] > 230) {
                originX = x;
                originY = y;
                break;
            }
        }
    }
    if (originX < 0) {
        fprintf(stderr, "fringe: the page's marker is not on screen\n");
        return 2;
    }

    int failures = 0, judged = 0;
    char line[512], name[256], expectation[32];
    long x, y, width, height;
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        bool known = sscanf(line, "%255s %31s %ld %ld %ld %ld", name, expectation, &x, &y, &width, &height) == 6
            && (!strcmp(expectation, "subpixel") || !strcmp(expectation, "grayscale")) && width > 0 && height > 0;
        if (!known) {
            printf("FAIL cannot judge \"%s\"\n", line);
            ++failures;
            continue;
        }
        long edges = 0;
        double fringe = strongFringe(originX + x, originY + y, width, height, &edges);
        bool wantsSubpixel = !strcmp(expectation, "subpixel");
        bool pass = edges >= minimumEdges && (wantsSubpixel ? fringe >= minimumSubpixel : fringe <= maximumGrayscale);
        printf("%s %-28s expects %-9s strong fringe %5.1f%% of %ld edge pixels\n", pass ? "PASS" : "FAIL", name, expectation, fringe, edges);
        failures += !pass;
        ++judged;
    }
    if (!judged) {
        printf("FAIL no cell was judged\n");
        return 1;
    }
    return failures ? 1 : 0;
}
