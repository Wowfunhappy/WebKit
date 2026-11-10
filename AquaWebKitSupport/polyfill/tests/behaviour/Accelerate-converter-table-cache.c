// 10.9 vImage's lookup-table cache, created by c/Accelerate.c before any converter. Built twice: linked
// with the polyfill, a fresh process whose eight threads create their first converters at once and
// convert through them never crashes, in 1000 such processes. Built without it (the argument
// "--without-polyfill"), some of up to 3000 do, in vLookupTable_Planar16 on a NULL table, which is the
// premise.
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef unsigned long vImage_Flags;
typedef long vImage_Error;
typedef struct vImageConverter *vImageConverterRef;
typedef struct { void *data; unsigned long height; unsigned long width; size_t rowBytes; } vImage_Buffer;
typedef struct {
    uint32_t bitsPerComponent;
    uint32_t bitsPerPixel;
    CGColorSpaceRef colorSpace;
    CGBitmapInfo bitmapInfo;
    uint32_t version;
    const CGFloat *decode;
    CGColorRenderingIntent renderingIntent;
} vImage_CGImageFormat;
extern vImageConverterRef vImageConverter_CreateWithCGImageFormat(const vImage_CGImageFormat *, const vImage_CGImageFormat *, const CGFloat *, vImage_Flags, vImage_Error *);
extern vImage_Error vImageConvert_AnyToAny(vImageConverterRef, const vImage_Buffer *, const vImage_Buffer *, void *, vImage_Flags);
extern void vImageConverter_Release(vImageConverterRef);

enum { threadCount = 8, side = 64, crashed = 70 };
static volatile int go;
static CGColorSpaceRef source, destination;

static void *convert(void *context)
{
    (void)context;
    while (!go) { }
    vImage_CGImageFormat from = { 8, 32, source, kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst, 0, NULL, kCGRenderingIntentDefault };
    vImage_CGImageFormat to = { 8, 32, destination, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst, 0, NULL, kCGRenderingIntentDefault };
    vImage_Error error = 0;
    vImageConverterRef converter = vImageConverter_CreateWithCGImageFormat(&from, &to, NULL, 0, &error);
    if (!converter)
        _exit(1);
    uint8_t *in = calloc(side * side, 4), *out = calloc(side * side, 4);
    for (int i = 0; i < side * side * 4; ++i)
        in[i] = (uint8_t)(i * 7);
    vImage_Buffer a = { in, side, side, side * 4 }, b = { out, side, side, side * 4 };
    if (vImageConvert_AnyToAny(converter, &a, &b, NULL, 0))
        _exit(1);
    vImageConverter_Release(converter);
    return NULL;
}

static void exitCrashed(int signal)
{
    (void)signal;
    _exit(crashed);
}

static int child(void)
{
    signal(SIGSEGV, exitCrashed);
    signal(SIGBUS, exitCrashed);
    source = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    destination = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    pthread_t threads[threadCount];
    for (int i = 0; i < threadCount; ++i)
        pthread_create(&threads[i], NULL, convert, NULL);
    go = 1;
    for (int i = 0; i < threadCount; ++i)
        pthread_join(threads[i], NULL);
    return 0;
}

// Runs up to `runs` fresh children; the number that crashed, stopping at the first when `untilCrash`.
static int crashes(const char *self, int runs, int untilCrash, int *ran)
{
    char *argv[] = { (char *)self, "--child", NULL };
    int count = 0;
    for (*ran = 0; *ran < runs; ++*ran) {
        pid_t pid;
        int status;
        if (posix_spawn(&pid, self, NULL, NULL, argv, NULL) || waitpid(pid, &status, 0) != pid)
            return -1;
        if (!WIFEXITED(status) || WEXITSTATUS(status) == 1)
            return -1;
        if (WEXITSTATUS(status) == crashed && ++count && untilCrash) {
            ++*ran;
            break;
        }
    }
    return count;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "--child"))
        return child();
    int ran;
    if (argc > 1 && !strcmp(argv[1], "--without-polyfill")) {
        int count = crashes(argv[0], 3000, 1, &ran);
        printf("10.9 vImageConverter_CreateWithCGImageFormat: %d crash(es) in %d processes\n", count, ran);
        return count > 0 ? 0 : 1;
    }
    int count = crashes(argv[0], 1000, 0, &ran);
    printf("polyfilled vImageConverter_CreateWithCGImageFormat: %d crash(es) in %d processes\n", count, ran);
    return count == 0 ? 0 : 1;
}
