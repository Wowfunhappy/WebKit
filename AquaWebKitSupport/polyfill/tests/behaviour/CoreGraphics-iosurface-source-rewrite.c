// An image CGIOSurfaceContextCreateImage made, drawn into another IOSurface context whose queue has not rendered,
// and then its surface written again, through the replacements in polyfills/c/CoreGraphics.c.
//
// Gate A: a canvas-sized scratch surface cleared, stroked, made into an image and drawn into an equally large
// destination each frame, with the destination left unflushed, costs under half of the same frames through
// 10.9's own definitions, which copy the whole scratch surface each frame, and about what 10.9's frames cost
// when the destination is flushed after each draw.
// Gate B: the destination shows the image's pixels, not the surface's later ones, and the last frame's stroke.
// Gate C: an image the caller keeps reads the pixels it was made with after its surface is written.
// Gate D: a destination its owner releases while a draw into it is recorded is freed by that release, which
// renders its queue.
// Gate E: a draw recorded on another thread is left to that thread: a write to the surface here does not render
// that destination's queue.
// Gate G: two threads running scratch frames at once each end with their own last frame.
// Gate H: a destination whose last reference is released on another thread while the image's surface is written
// renders the image, every time, without a crash.
// Gate I: a destination drawn by two threads under the caller's own mutex, one of which draws the image into it and
// then writes the image's surface without the mutex, runs to the end without a crash or a hang, while the other
// thread flushes the destination, and again while it makes images of the destination and draws them back into it.
// Gate F: a small image made and drawn a thousand times into one destination, its surface unwritten, costs about
// what 10.9's own definitions cost: nothing renders per draw.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
CGImageRef CGIOSurfaceContextCreateImage(CGContextRef);
IOSurfaceRef CGIOSurfaceContextGetSurface(CGContextRef);

static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static int failures;

static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

// 10.9's definitions, reached through dyld's image lookup: dlsym answers registered names with the archive's.
static void *systemFunction(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

typedef struct {
    void (*flush)(CGContextRef);
    CGImageRef (*createImage)(CGContextRef);
    void (*drawImage)(CGContextRef, CGRect, CGImageRef);
} Functions;

static CGContextRef createContext(int width, int height, CGColorSpaceRef space)
{
    int bytesPerElement = 4, bytesPerRow = width * 4;
    unsigned format = 'BGRA';
    CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &width);
    CFNumberRef h = CFNumberCreate(NULL, kCFNumberIntType, &height);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    CFNumberRef row = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerRow);
    CFNumberRef pixelFormat = CFNumberCreate(NULL, kCFNumberIntType, &format);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow, kIOSurfacePixelFormat };
    const void *values[] = { w, h, element, row, pixelFormat };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CGContextRef context = surface ? CGIOSurfaceContextCreate(surface, width, height, 8, 32, space, kBGRA) : NULL;
    CFRelease(properties);
    CFRelease(w);
    CFRelease(h);
    CFRelease(element);
    CFRelease(row);
    CFRelease(pixelFormat);
    if (surface)
        CFRelease(surface);
    if (context) {
        CGContextClearRect(context, CGRectMake(0, 0, width, height));
        CGContextFlush(context);
    }
    return context;
}

static void fill(CGContextRef context, CGRect rect, CGFloat r, CGFloat g, CGFloat b)
{
    CGContextSetRGBFillColor(context, r, g, b, 1);
    CGContextFillRect(context, rect);
}

// The pixel at (x, y) from the top-left, after the context's queue renders.
static void readPixel(CGContextRef context, int x, int y, int rgb[3])
{
    CGContextFlush(context);
    IOSurfaceRef surface = CGIOSurfaceContextGetSurface(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *p = (const unsigned char *)IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface) + x * 4;
    rgb[0] = p[2];
    rgb[1] = p[1];
    rgb[2] = p[0];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}

static int isColor(const int rgb[3], int r, int g, int b)
{
    return abs(rgb[0] - r) <= 2 && abs(rgb[1] - g) <= 2 && abs(rgb[2] - b) <= 2;
}

static double milliseconds(void)
{
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom)
        mach_timebase_info(&timebase);
    return mach_absolute_time() * (double)timebase.numer / timebase.denom / 1e6;
}

// Milliseconds per frame: the scratch surface cleared and given a 20-pixel square at x = 20 * frame, made into
// an image that is drawn over the whole destination and released. The destination renders at the end, or after
// each draw with `flushEachFrame`.
static double scratchFrames(const Functions *functions, CGContextRef scratch, CGContextRef destination, int width, int height, int frames,
    int flushEachFrame)
{
    CGRect whole = CGRectMake(0, 0, width, height);
    double start = milliseconds();
    for (int frame = 0; frame < frames; frame++) {
        CGContextClearRect(scratch, whole);
        fill(scratch, CGRectMake(20 * frame, height - 20, 20, 20), 0, 0, 1);
        functions->flush(scratch);
        CGImageRef image = functions->createImage(scratch);
        functions->drawImage(destination, whole, image);
        CGImageRelease(image);
        if (flushEachFrame)
            functions->flush(destination);
    }
    double elapsed = milliseconds() - start;
    functions->flush(destination);
    return elapsed / frames;
}

static int destinationFreed;
static void noteDestinationFreed(void *pointer, void *info)
{
    (void)pointer;
    (void)info;
    destinationFreed = 1;
}

typedef struct {
    CGImageRef image;
    CGContextRef destination;
} OtherThreadDraw;

static void *drawOnOtherThread(void *argument)
{
    OtherThreadDraw *draw = argument;
    CGContextDrawImage(draw->destination, CGRectMake(0, 0, 64, 64), draw->image);
    return NULL;
}

// The pixel at (x, y) from the top-left as the surface holds it, without rendering any queue.
static void readSurfacePixel(IOSurfaceRef surface, int x, int y, int rgb[3])
{
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *p = (const unsigned char *)IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface) + x * 4;
    rgb[0] = p[2];
    rgb[1] = p[1];
    rgb[2] = p[0];
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}

static void *releaseOnOtherThread(void *context)
{
    CGContextRelease((CGContextRef)context);
    return NULL;
}

typedef struct {
    int last[3];
} ScratchThread;

static void *scratchThread(void *argument)
{
    ScratchThread *result = argument;
    Functions replacement = { CGContextFlush, CGIOSurfaceContextCreateImage, CGContextDrawImage };
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const int width = 512, height = 2048, frames = 20;
    CGContextRef scratch = createContext(width, height, sRGB);
    CGContextRef destination = createContext(width, height, sRGB);
    scratchFrames(&replacement, scratch, destination, width, height, frames, 0);
    readPixel(destination, 20 * (frames - 1) + 10, 10, result->last);
    CGContextRelease(scratch);
    CGContextRelease(destination);
    CGColorSpaceRelease(sRGB);
    return NULL;
}

static pthread_mutex_t sharedDestinationMutex = PTHREAD_MUTEX_INITIALIZER;
static CGContextRef sharedDestination;
static volatile int sharedDestinationStop;
static int sharedDestinationSnapshots;

static void *drawSharedDestination(void *unused)
{
    (void)unused;
    unsigned i = 0;
    while (!sharedDestinationStop) {
        pthread_mutex_lock(&sharedDestinationMutex);
        for (int k = 0; k < 20; k++, i++) {
            CGContextSetRGBFillColor(sharedDestination, i & 1, 0, 1, 1);
            CGContextFillRect(sharedDestination, CGRectMake(i % 200, k, 8, 8));
        }
        if (sharedDestinationSnapshots) {
            CGImageRef snapshot = CGIOSurfaceContextCreateImage(sharedDestination);
            CGContextDrawImage(sharedDestination, CGRectMake(100, 100, 30, 30), snapshot);
            CGImageRelease(snapshot);
        } else if (!(i & 63))
            CGContextFlush(sharedDestination);
        pthread_mutex_unlock(&sharedDestinationMutex);
    }
    return NULL;
}

static void sharedDestinationHung(int signal)
{
    (void)signal;
    static const char message[] = "  I: hung\nFAIL\n";
    write(1, message, sizeof message - 1);
    _exit(1);
}

int main(void)
{
    Functions replacement = { CGContextFlush, CGIOSurfaceContextCreateImage, CGContextDrawImage };
    Functions system = { (void (*)(CGContextRef))systemFunction("_CGContextFlush"),
        (CGImageRef (*)(CGContextRef))systemFunction("_CGIOSurfaceContextCreateImage"),
        (void (*)(CGContextRef, CGRect, CGImageRef))systemFunction("_CGContextDrawImage") };
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!system.flush || !system.createImage || !system.drawImage || !sRGB)
        return 1;

    printf("Scratch surface drawn into an unflushed destination each frame:\n");
    {
        const int width = 1774, height = 9021, frames = 12;
        CGContextRef scratch = createContext(width, height, sRGB);
        CGContextRef destination = createContext(width, height, sRGB);
        if (!scratch || !destination)
            return 1;
        scratchFrames(&replacement, scratch, destination, width, height, 2, 0);
        double replaced = scratchFrames(&replacement, scratch, destination, width, height, frames, 0);
        int last[3], first[3], cleared[3];
        readPixel(destination, 20 * (frames - 1) + 10, 10, last);
        readPixel(destination, 10, 10, first);
        readPixel(destination, 10, 100, cleared);
        scratchFrames(&system, scratch, destination, width, height, 2, 0);
        double original = scratchFrames(&system, scratch, destination, width, height, frames, 0);
        double flushed = scratchFrames(&system, scratch, destination, width, height, frames, 1);
        printf("    ms per frame: replacements %.2f, 10.9 %.2f, 10.9 flushing the destination each frame %.2f\n", replaced, original, flushed);
        check(replaced * 2 < original && replaced < flushed * 1.5 + 2, "A: no copy of the scratch surface per frame");
        printf("    last square %d,%d,%d, first square %d,%d,%d, elsewhere %d,%d,%d\n",
            last[0], last[1], last[2], first[0], first[1], first[2], cleared[0], cleared[1], cleared[2]);
        check(isColor(last, 0, 0, 255) && isColor(first, 0, 0, 255) && isColor(cleared, 0, 0, 0),
            "B: destination holds every frame's square drawn over the last");
        CGContextRelease(scratch);
        CGContextRelease(destination);
    }

    printf("Image drawn into an unflushed destination, then its surface written:\n");
    {
        CGContextRef source = createContext(64, 64, sRGB);
        CGContextRef destination = createContext(64, 64, sRGB);
        CGContextRef later = createContext(64, 64, sRGB);
        fill(source, CGRectMake(0, 0, 64, 64), 0, 1, 0);
        CGImageRef image = CGIOSurfaceContextCreateImage(source);
        CGContextDrawImage(destination, CGRectMake(0, 0, 64, 64), image);
        fill(source, CGRectMake(0, 0, 64, 64), 1, 0, 0);
        CGContextFlush(source);
        CGContextDrawImage(later, CGRectMake(0, 0, 64, 64), image);
        int drawn[3], kept[3], surface[3];
        readPixel(destination, 32, 32, drawn);
        readPixel(later, 32, 32, kept);
        readPixel(source, 32, 32, surface);
        printf("    destination %d,%d,%d, kept image %d,%d,%d, surface %d,%d,%d\n",
            drawn[0], drawn[1], drawn[2], kept[0], kept[1], kept[2], surface[0], surface[1], surface[2]);
        check(isColor(drawn, 0, 255, 0) && isColor(surface, 255, 0, 0), "B: destination shows the image, surface its write");
        check(isColor(kept, 0, 255, 0), "C: a kept image reads the pixels it was made with");
        CGImageRelease(image);
        CGContextRelease(source);
        CGContextRelease(destination);
        CGContextRelease(later);
    }

    printf("Destination released by its owner while a draw into it is recorded:\n");
    {
        CGContextRef source = createContext(64, 64, sRGB);
        CGContextRef destination = createContext(64, 64, sRGB);
        IOSurfaceRef surface = (IOSurfaceRef)CFRetain(CGIOSurfaceContextGetSurface(destination));
        CFAllocatorContext allocatorContext = { .deallocate = noteDestinationFreed };
        CFAllocatorRef watcher = CFAllocatorCreate(NULL, &allocatorContext);
        CFDataRef watch = CFDataCreateWithBytesNoCopy(NULL, (const UInt8 *)destination, 1, watcher);
        objc_setAssociatedObject((id)destination, (const void *)noteDestinationFreed, (id)watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFRelease(watch);
        CFRelease(watcher);
        fill(source, CGRectMake(0, 0, 64, 64), 0, 1, 0);
        CGImageRef image = CGIOSurfaceContextCreateImage(source);
        CGContextDrawImage(destination, CGRectMake(0, 0, 64, 64), image);
        CGImageRelease(image);
        long held = CFGetRetainCount(destination);
        CGContextRelease(destination);
        int released[3];
        readSurfacePixel(surface, 32, 32, released);
        printf("    retain count while recorded %ld; freed at the owner's release %d; surface %d,%d,%d\n",
            held, destinationFreed, released[0], released[1], released[2]);
        check(held == 1 && destinationFreed, "D: the record does not hold the destination");
        check(isColor(released, 0, 255, 0), "D: the owner's release renders the destination's queue");
        fill(source, CGRectMake(0, 0, 64, 64), 1, 0, 0);
        CGContextFlush(source);
        CFRelease(surface);
        CGContextRelease(source);
    }

    printf("Draw recorded on another thread:\n");
    {
        CGContextRef source = createContext(64, 64, sRGB);
        CGContextRef destination = createContext(64, 64, sRGB);
        fill(source, CGRectMake(0, 0, 64, 64), 0, 1, 0);
        CGImageRef image = CGIOSurfaceContextCreateImage(source);
        OtherThreadDraw draw = { image, destination };
        pthread_t thread;
        pthread_create(&thread, NULL, drawOnOtherThread, &draw);
        pthread_join(thread, NULL);
        fill(source, CGRectMake(0, 0, 64, 64), 1, 0, 0);
        int unrendered[3], rendered[3];
        readSurfacePixel(CGIOSurfaceContextGetSurface(destination), 32, 32, unrendered);
        readPixel(destination, 32, 32, rendered);
        printf("    destination before its own flush %d,%d,%d, after %d,%d,%d\n",
            unrendered[0], unrendered[1], unrendered[2], rendered[0], rendered[1], rendered[2]);
        check(isColor(unrendered, 0, 0, 0), "E: a write on this thread leaves another thread's destination unrendered");
        check(isColor(rendered, 0, 255, 0), "E: the destination's own flush paints the image");
        CGImageRelease(image);
        CGContextRelease(source);
        CGContextRelease(destination);
    }

    printf("Scratch frames on two threads at once:\n");
    {
        ScratchThread threads[2] = { { { 0 } }, { { 0 } } };
        pthread_t ids[2];
        for (int i = 0; i < 2; i++)
            pthread_create(&ids[i], NULL, scratchThread, &threads[i]);
        for (int i = 0; i < 2; i++)
            pthread_join(ids[i], NULL);
        printf("    thread 0 last square %d,%d,%d, thread 1 %d,%d,%d\n", threads[0].last[0], threads[0].last[1], threads[0].last[2],
            threads[1].last[0], threads[1].last[1], threads[1].last[2]);
        check(isColor(threads[0].last, 0, 0, 255) && isColor(threads[1].last, 0, 0, 255), "G: both threads' destinations hold their last frames");
    }

    printf("Destination released on another thread while the source is written:\n");
    {
        int painted = 0;
        for (int round = 0; round < 40; round++) {
            CGContextRef source = createContext(256, 256, sRGB);
            CGContextRef destination = createContext(256, 256, sRGB);
            IOSurfaceRef surface = (IOSurfaceRef)CFRetain(CGIOSurfaceContextGetSurface(destination));
            fill(source, CGRectMake(0, 0, 256, 256), 0, 1, 0);
            CGImageRef image = CGIOSurfaceContextCreateImage(source);
            CGContextDrawImage(destination, CGRectMake(0, 0, 256, 256), image);
            CGImageRelease(image);
            pthread_t releaser;
            pthread_create(&releaser, NULL, releaseOnOtherThread, destination);
            for (int write = 0; write < 50; write++)
                fill(source, CGRectMake(write, write, 4, 4), 1, 0, 0);
            pthread_join(releaser, NULL);
            int rgb[3];
            readSurfacePixel(surface, 128, 128, rgb);
            painted += isColor(rgb, 0, 255, 0);
            CFRelease(surface);
            CGContextFlush(source);
            CGContextRelease(source);
        }
        printf("    destinations holding the image after their release: %d of 40\n", painted);
        check(painted == 40, "H: every destination renders, none crashes");
    }

    for (sharedDestinationSnapshots = 0; sharedDestinationSnapshots < 2; sharedDestinationSnapshots++) {
        printf("Destination shared by two threads under the caller's mutex, the other thread %s:\n",
            sharedDestinationSnapshots ? "drawing images of it back into it" : "flushing it");
        signal(SIGALRM, sharedDestinationHung);
        alarm(120);
        sharedDestinationStop = 0;
        CGContextRef source = createContext(256, 256, sRGB);
        sharedDestination = createContext(256, 256, sRGB);
        pthread_t other;
        pthread_create(&other, NULL, drawSharedDestination, NULL);
        for (int i = 0; i < 10000; i++) {
            fill(source, CGRectMake(i % 250, 0, 4, 4), 0, 1, 0);
            CGImageRef image = CGIOSurfaceContextCreateImage(source);
            pthread_mutex_lock(&sharedDestinationMutex);
            CGContextDrawImage(sharedDestination, CGRectMake(0, 0, 64, 64), image);
            pthread_mutex_unlock(&sharedDestinationMutex);
            CGImageRelease(image);
        }
        sharedDestinationStop = 1;
        pthread_join(other, NULL);
        alarm(0);
        check(1, "I: ran to the end");
        CGContextRelease(sharedDestination);
        CGContextRelease(source);
    }

    printf("A small image drawn a thousand times, its surface unwritten:\n");
    {
        CGContextRef sprite = createContext(64, 64, sRGB);
        CGContextRef destination = createContext(1600, 1200, sRGB);
        fill(sprite, CGRectMake(0, 0, 20, 20), 1, 0, 0);
        CGContextFlush(sprite);
        double best[2] = { INFINITY, INFINITY };
        for (int run = 0; run < 6; run++) {
            const Functions *functions = run & 1 ? &system : &replacement;
            double start = milliseconds();
            for (int i = 0; i < 1000; i++) {
                CGImageRef image = functions->createImage(sprite);
                functions->drawImage(destination, CGRectMake((i * 37) % 1500, (i * 53) % 1100, 64, 64), image);
                CGImageRelease(image);
            }
            functions->flush(destination);
            best[run & 1] = fmin(best[run & 1], milliseconds() - start);
        }
        printf("    ms per 1000 draws: replacements %.2f, 10.9 %.2f\n", best[0], best[1]);
        check(best[0] < best[1] * 2 + 2, "F: no render per draw");
        CGContextRelease(sprite);
        CGContextRelease(destination);
    }

    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
