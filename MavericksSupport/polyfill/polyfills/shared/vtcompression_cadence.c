/*
 * VTCompressionSessionCreate and VTCompressionSessionEncodeFrame -- DELIBERATE OVERRIDES of functions
 * 10.9 has.
 *
 * A frame submitted without a duration tells 10.9's software H.264 encoder its frame rate through the
 * session's frame count over the frame's ABSOLUTE presentation time, truncated to 32 signed bits of
 * 1/100000 s, rather than over the time since the session's first frame. The answer depends on where
 * the caller's clock started (measured on 10.9, mean slice QP over frames 120-149 of the same 30 fps
 * stream: origin 0 -> 34, origin 30 s -> 14, origin 75510 s -> 51), so the rate controller runs the
 * stream at the quantizer floor or ceiling. libwebrtc's RTCVideoEncoderH264 and gst-plugins-bad's
 * vtenc both submit frames without durations, on clocks that did not start at the session.
 *
 * Every frame after a session's first that arrives without a duration carries the session's average
 * frame duration since its first frame -- the encoder's own frames-over-elapsed measure, taken from the
 * right origin -- and a frame that states its duration keeps it. The encoder copies a frame's duration
 * into its output sample, so the output callback is wrapped and hands back a sample whose supplied
 * duration is invalid again, which is what the caller submitted. The caller's own output callback,
 * refcons and statuses reach it unchanged.
 *
 * Per-session state lives in an associated object on the session and goes with it. Each frame's
 * refcon is wrapped; 10.9 delivers a frame's output on the thread that submits or completes it and
 * discards the frames still queued when the session is invalidated or released without calling back
 * (measured), so the state owns the wrappers still outstanding and frees them when it goes. A session
 * created without an output callback has nothing to wrap and is left alone.
 *
 * Plain C, with the frameworks' types declared locally and their entry points taken from the loaded
 * images' own symbol tables: deps/build_deps.sh compiles this file into the gap archive force-loaded
 * into every media dylib, and polyfill/build-polyfill.sh compiles it into libpolyfill.a for WebKit,
 * where WK_POLYFILL_REGISTERED adds the registry entries.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include "../c/wk_symbols.h"

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} WKCMTime;

typedef struct {
    WKCMTime duration;
    WKCMTime presentationTimeStamp;
    WKCMTime decodeTimeStamp;
} WKCMSampleTimingInfo;

enum { WKCMTimeFlagsValid = 1, WKCMTimeFlagsImpliedValueFlagsMask = 0x1c };

typedef struct WKOpaqueVTCompressionSession *WKVTCompressionSessionRef;
typedef struct WKOpaqueCMSampleBuffer *WKCMSampleBufferRef;
typedef void (*WKVTCompressionOutputCallback)(void *outputCallbackRefCon, void *sourceFrameRefCon,
    OSStatus, uint32_t infoFlags, WKCMSampleBufferRef);

typedef OSStatus (*WKVTCompressionSessionCreateFunction)(CFAllocatorRef, int32_t width, int32_t height,
    uint32_t codecType, CFDictionaryRef encoderSpecification, CFDictionaryRef sourceImageBufferAttributes,
    CFAllocatorRef compressedDataAllocator, WKVTCompressionOutputCallback, void *outputCallbackRefCon,
    WKVTCompressionSessionRef *);
typedef OSStatus (*WKVTCompressionSessionEncodeFrameFunction)(WKVTCompressionSessionRef, CFTypeRef imageBuffer,
    WKCMTime presentationTimeStamp, WKCMTime duration, CFDictionaryRef frameProperties, void *sourceFrameRefCon,
    uint32_t *infoFlagsOut);
typedef WKCMTime (*WKCMTimeSubtractFunction)(WKCMTime, WKCMTime);
typedef Float64 (*WKCMTimeGetSecondsFunction)(WKCMTime);
typedef WKCMTime (*WKCMTimeMultiplyByFloat64Function)(WKCMTime, Float64);
typedef OSStatus (*WKCMSampleBufferGetSampleTimingInfoArrayFunction)(WKCMSampleBufferRef, CFIndex,
    WKCMSampleTimingInfo *, CFIndex *);
typedef OSStatus (*WKCMSampleBufferCreateCopyWithNewTimingFunction)(CFAllocatorRef, WKCMSampleBufferRef, CFIndex,
    const WKCMSampleTimingInfo *, WKCMSampleBufferRef *);
typedef void *(*WKobjc_getAssociatedObjectFunction)(const void *, const void *);
typedef void (*WKobjc_setAssociatedObjectFunction)(const void *, const void *, const void *, uintptr_t);
typedef const void *(*WKsel_registerNameFunction)(const char *);

static const char kWKVideoToolboxImage[] = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox";
static const char kWKCoreMediaImage[] = "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia";
static const char kWKObjCImage[] = "/usr/lib/libobjc.A.dylib";

// VideoToolbox's two entry points are the ones this file replaces, so they are taken from the framework's
// own symbol table: dlsym answers a replaced name with the replacement. The rest are asked of dlsym, which
// also runs the resolver 10.9's libobjc exports its association functions through.
static void *wk_cadence_image_symbol(void **slot, const char *image, const char *symbol)
{
    void *address = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!address) {
        wk_image loadedImage;
        if (!wk_find_image(image, &loadedImage)) {
            if (!dlopen(image, RTLD_LAZY | RTLD_LOCAL) || !wk_find_image(image, &loadedImage))
                wk_patch_fail(symbol, "its image does not load");
        }
        address = wk_symbol_in_image(&loadedImage, symbol);
        if (!address)
            wk_patch_fail(symbol, "absent from its image");
        __atomic_store_n(slot, address, __ATOMIC_RELAXED);
    }
    return address;
}

static void *wk_cadence_symbol(void **slot, const char *image, const char *symbol)
{
    void *address = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!address) {
        void *handle = dlopen(image, RTLD_LAZY | RTLD_LOCAL);
        address = handle ? dlsym(handle, symbol) : NULL;
        if (!address)
            wk_patch_fail(symbol, "absent from its image");
        __atomic_store_n(slot, address, __ATOMIC_RELAXED);
    }
    return address;
}

static WKVTCompressionSessionCreateFunction wk_system_VTCompressionSessionCreate(void)
{
    static void *cached;
    return (WKVTCompressionSessionCreateFunction)wk_cadence_image_symbol(&cached, kWKVideoToolboxImage, "_VTCompressionSessionCreate");
}

static WKVTCompressionSessionEncodeFrameFunction wk_system_VTCompressionSessionEncodeFrame(void)
{
    static void *cached;
    return (WKVTCompressionSessionEncodeFrameFunction)wk_cadence_image_symbol(&cached, kWKVideoToolboxImage, "_VTCompressionSessionEncodeFrame");
}

#define WK_CADENCE_FUNCTION(image, name) \
    static WK##name##Function wk_system_##name(void) \
    { \
        static void *cached; \
        return (WK##name##Function)wk_cadence_symbol(&cached, image, #name); \
    }

WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMTimeSubtract)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMTimeGetSeconds)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMTimeMultiplyByFloat64)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleTimingInfoArray)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferCreateCopyWithNewTiming)

WK_CADENCE_FUNCTION(kWKObjCImage, objc_getAssociatedObject)
WK_CADENCE_FUNCTION(kWKObjCImage, objc_setAssociatedObject)
WK_CADENCE_FUNCTION(kWKObjCImage, sel_registerName)

// Every image that force-loads this file has its own copy of it, and a session one image creates may be
// encoded from another, so the association key is a registered selector: the same address in every image.
static const void *wk_cadence_session_key(void)
{
    static const void *key;
    const void *value = __atomic_load_n(&key, __ATOMIC_RELAXED);
    if (!value) {
        value = wk_system_sel_registerName()("WKVTCompressionSessionCadence");
        __atomic_store_n(&key, value, __ATOMIC_RELAXED);
    }
    return value;
}

static int wk_time_is_numeric(WKCMTime time)
{
    return (time.flags & (WKCMTimeFlagsValid | WKCMTimeFlagsImpliedValueFlagsMask)) == WKCMTimeFlagsValid;
}

typedef struct WKCadenceFrame {
    struct WKCadenceFrame *previous;
    struct WKCadenceFrame *next;
    void *sourceFrameRefCon;
    int durationSupplied;
} WKCadenceFrame;

typedef struct {
    os_unfair_lock lock;
    WKVTCompressionOutputCallback outputCallback;
    void *outputCallbackRefCon;
    WKCMTime firstPresentationTime;
    int64_t frameCount;
    WKCadenceFrame outstanding;
} WKCadenceSession;

static void wk_cadence_session_free(void *pointer, void *info)
{
    (void)info;
    WKCadenceSession *session = pointer;
    for (WKCadenceFrame *frame = session->outstanding.next; frame != &session->outstanding;) {
        WKCadenceFrame *next = frame->next;
        free(frame);
        frame = next;
    }
    free(session);
}

static CFAllocatorRef wk_cadenceSessionDeallocator;

static void wk_cadence_create_session_deallocator(void)
{
    CFAllocatorContext context = { 0 };
    context.deallocate = wk_cadence_session_free;
    wk_cadenceSessionDeallocator = CFAllocatorCreate(kCFAllocatorDefault, &context);
    if (!wk_cadenceSessionDeallocator)
        wk_patch_fail("VTCompressionSessionCreate", "no memory for the cadence deallocator");
}

static CFAllocatorRef wk_cadence_session_deallocator(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_cadence_create_session_deallocator);
    return wk_cadenceSessionDeallocator;
}

static void wk_cadence_output(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status,
    uint32_t infoFlags, WKCMSampleBufferRef sampleBuffer)
{
    WKCadenceSession *session = outputCallbackRefCon;
    WKCadenceFrame *frame = sourceFrameRefCon;
    os_unfair_lock_lock(&session->lock);
    frame->previous->next = frame->next;
    frame->next->previous = frame->previous;
    os_unfair_lock_unlock(&session->lock);
    void *callerRefCon = frame->sourceFrameRefCon;
    int durationSupplied = frame->durationSupplied;
    free(frame);

    WKCMSampleBufferRef delivered = sampleBuffer;
    CFIndex count = 0;
    if (durationSupplied && sampleBuffer
        && !wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, 0, NULL, &count) && count > 0) {
        WKCMSampleTimingInfo *timing = malloc((size_t)count * sizeof(*timing));
        if (!timing || wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, count, timing, &count))
            wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample's timing did not read");
        for (CFIndex i = 0; i < count; ++i)
            timing[i].duration = (WKCMTime) { 0, 0, 0, 0 };
        delivered = NULL;
        if (wk_system_CMSampleBufferCreateCopyWithNewTiming()(kCFAllocatorDefault, sampleBuffer, count, timing, &delivered) || !delivered)
            wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample did not copy");
        free(timing);
    }
    session->outputCallback(session->outputCallbackRefCon, callerRefCon, status, infoFlags, delivered);
    if (delivered != sampleBuffer)
        CFRelease(delivered);
}

OSStatus VTCompressionSessionCreate(CFAllocatorRef allocator, int32_t width, int32_t height, uint32_t codecType,
    CFDictionaryRef encoderSpecification, CFDictionaryRef sourceImageBufferAttributes,
    CFAllocatorRef compressedDataAllocator, WKVTCompressionOutputCallback outputCallback,
    void *outputCallbackRefCon, WKVTCompressionSessionRef *compressionSessionOut)
{
    if (!outputCallback) {
        return wk_system_VTCompressionSessionCreate()(allocator, width, height, codecType, encoderSpecification,
            sourceImageBufferAttributes, compressedDataAllocator, outputCallback, outputCallbackRefCon, compressionSessionOut);
    }

    WKCadenceSession *session = calloc(1, sizeof(*session));
    if (!session)
        wk_patch_fail("VTCompressionSessionCreate", "no memory for the session's cadence");
    session->lock = OS_UNFAIR_LOCK_INIT;
    session->outputCallback = outputCallback;
    session->outputCallbackRefCon = outputCallbackRefCon;
    session->outstanding.previous = &session->outstanding;
    session->outstanding.next = &session->outstanding;

    OSStatus status = wk_system_VTCompressionSessionCreate()(allocator, width, height, codecType, encoderSpecification,
        sourceImageBufferAttributes, compressedDataAllocator, wk_cadence_output, session, compressionSessionOut);
    if (status || !compressionSessionOut || !*compressionSessionOut) {
        free(session);
        return status;
    }

    CFDataRef owner = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (const UInt8 *)session, sizeof(*session),
        wk_cadence_session_deallocator());
    if (!owner)
        wk_patch_fail("VTCompressionSessionCreate", "no memory for the session's cadence owner");
    wk_system_objc_setAssociatedObject()(*compressionSessionOut, wk_cadence_session_key(), owner, 1 /* OBJC_ASSOCIATION_RETAIN_NONATOMIC */);
    CFRelease(owner);
    return status;
}

OSStatus VTCompressionSessionEncodeFrame(WKVTCompressionSessionRef compressionSession, CFTypeRef imageBuffer,
    WKCMTime presentationTimeStamp, WKCMTime duration, CFDictionaryRef frameProperties, void *sourceFrameRefCon,
    uint32_t *infoFlagsOut)
{
    CFDataRef owner = compressionSession
        ? wk_system_objc_getAssociatedObject()(compressionSession, wk_cadence_session_key()) : NULL;
    if (!owner) {
        return wk_system_VTCompressionSessionEncodeFrame()(compressionSession, imageBuffer, presentationTimeStamp,
            duration, frameProperties, sourceFrameRefCon, infoFlagsOut);
    }
    WKCadenceSession *session = (WKCadenceSession *)CFDataGetBytePtr(owner);

    WKCadenceFrame *frame = calloc(1, sizeof(*frame));
    if (!frame)
        wk_patch_fail("VTCompressionSessionEncodeFrame", "no memory for a frame's cadence");
    frame->sourceFrameRefCon = sourceFrameRefCon;

    os_unfair_lock_lock(&session->lock);
    if (wk_time_is_numeric(presentationTimeStamp)) {
        if (!session->frameCount)
            session->firstPresentationTime = presentationTimeStamp;
        else if (!(duration.flags & WKCMTimeFlagsValid)) {
            WKCMTime elapsed = wk_system_CMTimeSubtract()(presentationTimeStamp, session->firstPresentationTime);
            if (wk_time_is_numeric(elapsed) && wk_system_CMTimeGetSeconds()(elapsed) > 0) {
                duration = wk_system_CMTimeMultiplyByFloat64()(elapsed, 1.0 / (Float64)session->frameCount);
                frame->durationSupplied = 1;
            }
        }
        ++session->frameCount;
    }
    frame->next = &session->outstanding;
    frame->previous = session->outstanding.previous;
    frame->previous->next = frame;
    session->outstanding.previous = frame;
    os_unfair_lock_unlock(&session->lock);

    OSStatus status = wk_system_VTCompressionSessionEncodeFrame()(compressionSession, imageBuffer, presentationTimeStamp,
        duration, frameProperties, frame, infoFlagsOut);
    return status;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(VTCompressionSessionCreate, "VideoToolbox", &VTCompressionSessionCreate, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(VTCompressionSessionEncodeFrame, "VideoToolbox", &VTCompressionSessionEncodeFrame, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
