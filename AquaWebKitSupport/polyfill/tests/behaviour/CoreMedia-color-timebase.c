#include <CoreFoundation/CoreFoundation.h>
#define CMTIMEBASE_USE_SOURCE_TERMINOLOGY 1
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    assert(CFEqual(kCMFormatDescriptionTransferFunction_sRGB, CFSTR("IEC_sRGB")));
    assert(CFEqual(kCMFormatDescriptionTransferFunction_sRGB, kCVImageBufferTransferFunction_sRGB));

    void* native = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY | RTLD_FIRST);
    assert(native);
    OSStatus (*createNative)(CFAllocatorRef, CMClockRef, CMTimebaseRef*) = dlsym(native, "CMTimebaseCreateWithMasterClock");
    CMClockRef (*getClock)(CMTimebaseRef) = dlsym(native, "CMTimebaseGetMasterClock");
    assert(createNative && getClock);

    CMClockRef clock = CMClockGetHostTimeClock();
    CMTimebaseRef timebase = NULL;
    assert(CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, clock, &timebase) == noErr);
    assert(timebase && CFGetTypeID(timebase) == CMTimebaseGetTypeID());
    assert(getClock(timebase) == clock);
    assert(CMTimebaseGetRate(timebase) == 0);
    assert(CMTimeCompare(CMTimebaseGetTime(timebase), kCMTimeZero) == 0);
    assert(CMTimebaseSetTime(timebase, CMTimeMake(7, 1)) == noErr);
    assert(CMTimeCompare(CMTimebaseGetTime(timebase), CMTimeMake(7, 1)) == 0);
    assert(CMTimebaseSetRate(timebase, 2) == noErr);
    usleep(20000);
    assert(CMTimeCompare(CMTimebaseGetTime(timebase), CMTimeMake(7, 1)) > 0);
    CFRelease(timebase);

    CMTimebaseRef nativeOutput = NULL;
    CMTimebaseRef output = NULL;
    OSStatus expected = createNative(kCFAllocatorDefault, NULL, &nativeOutput);
    OSStatus actual = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, NULL, &output);
    assert(expected != noErr && actual == expected);
    assert(!nativeOutput && !output);
    dlclose(native);
    puts("PASS: CoreMedia sRGB identity and native source-clock timebase semantics");
    return 0;
}
