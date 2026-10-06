/*
 * VTIsHardwareDecodeSupported (VideoToolbox, 10.13+), absent on 10.9.
 *
 * Answered with the question the real API answers: can THIS machine's VideoToolbox open a
 * hardware-only decompression session for the codec? 10.9 can be asked directly -- both
 * kVTVideoDecoderSpecification_{Enable,Require}HardwareAcceleratedVideoDecoder exist here, and
 * VTDecompressionSessionCreate on a bare CMVideoFormatDescription resolves the decoder from the
 * codec type alone (measured on a hardware-decode-less machine: the same bare description opens
 * a software session (noErr) while RequireHardware answers kVTCouldNotFindVideoDecoderErr).
 * A hardware-capable Mac answers true for the codecs its GPU decodes; a machine without a
 * hardware decoder for the codec answers false, through the same probe either way. Probed once
 * per codec type. Correct for any caller, not one caller's convenience.
 *
 * gst-plugins-bad's applemedia plugin calls this UNGUARDED from gst_vtdec_check_vp9_support and
 * gst_vtdec_check_av1_support (sys/applemedia/vtdec.c), reached from gst_vtdec_getcaps -- the
 * caps query decodebin runs to auto-plug an element. As a weak import it binds NULL on 10.9 and
 * the call goes through address 0, taking WebContent down during a plain caps query.
 *
 * VideoToolbox and CoreMedia are resolved with dlsym at first use, so this object -- force-loaded
 * into every media dylib by deps/build_deps.sh's gap archive -- adds no link-time framework
 * dependency beyond the CoreFoundation every deps link already carries (toolchain clang.cfg).
 *
 * Plain C so the non-WebKit builds that carry no polyfill registry compile this same source.
 *
 * WK_POLYFILL_REGISTERED is defined only by polyfill/build-polyfill.sh, i.e. only when
 * this file is built into libpolyfill.a for WebKit. It adds the registry entry and nothing else.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

/* VideoToolbox/CoreMedia types, declared locally: the frameworks are reached only through
 * dlsym, never through their headers or stub libraries. */
typedef struct WKOpaqueCMFormatDescription *WKCMFormatDescriptionRef;
typedef struct WKOpaqueVTDecompressionSession *WKVTDecompressionSessionRef;
typedef void (*WKVTDecompressionOutputCallback)(void *, void *, OSStatus, uint32_t,
    void *, int64_t, int64_t);
typedef struct {
    WKVTDecompressionOutputCallback decompressionOutputCallback;
    void *decompressionOutputRefCon;
} WKVTDecompressionOutputCallbackRecord;

typedef OSStatus (*WKCMVideoFormatDescriptionCreate)(CFAllocatorRef, uint32_t, int32_t,
    int32_t, CFDictionaryRef, WKCMFormatDescriptionRef *);
typedef OSStatus (*WKVTDecompressionSessionCreate)(CFAllocatorRef, WKCMFormatDescriptionRef,
    CFDictionaryRef, CFDictionaryRef, const WKVTDecompressionOutputCallbackRecord *,
    WKVTDecompressionSessionRef *);
typedef void (*WKVTDecompressionSessionInvalidate)(WKVTDecompressionSessionRef);

static void *wk_vt_sym(const char *name)
{
    static void *handle;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
            RTLD_LAZY);
        if (!handle)
            return NULL;
    }
    return dlsym(handle, name);
}

static void *wk_cm_sym(const char *name)
{
    static void *handle;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
        if (!handle)
            return NULL;
    }
    return dlsym(handle, name);
}

static void wk_vt_probe_output(void *refcon, void *sourceRefCon, OSStatus status,
    uint32_t flags, void *imageBuffer, int64_t pts, int64_t duration)
{
    (void)refcon; (void)sourceRefCon; (void)status; (void)flags;
    (void)imageBuffer; (void)pts; (void)duration;
}

/* The answers a RequireHardware session attempt gives about a codec type. A status naming the
 * decoder missing settles the question; one reporting it busy or malfunctioning describes this
 * instant rather than the machine, and leaves the question open. */
typedef enum {
    WK_VT_HW_ABSENT,
    WK_VT_HW_PRESENT,
    WK_VT_HW_UNDETERMINED,
} WKVTHardwareAnswer;

/* 10.9's VideoToolbox reports a missing decoder with a legacy codec-not-found value as well as
 * the named one. */
#define WK_VT_COULD_NOT_FIND_VIDEO_DECODER        ((OSStatus)-12906)
#define WK_VT_COULD_NOT_FIND_VIDEO_DECODER_LEGACY ((OSStatus)-8973)

/* One RequireHardware session attempt for the codec type. A framework that will not load or a
 * codec type no description can be built for leaves nothing to decode with. */
static WKVTHardwareAnswer wk_vt_probe_hardware_decode(uint32_t codecType)
{
    WKCMVideoFormatDescriptionCreate descCreate =
        (WKCMVideoFormatDescriptionCreate)wk_cm_sym("CMVideoFormatDescriptionCreate");
    WKVTDecompressionSessionCreate sessionCreate =
        (WKVTDecompressionSessionCreate)wk_vt_sym("VTDecompressionSessionCreate");
    WKVTDecompressionSessionInvalidate sessionInvalidate =
        (WKVTDecompressionSessionInvalidate)wk_vt_sym("VTDecompressionSessionInvalidate");
    CFStringRef *enableKey =
        (CFStringRef *)wk_vt_sym("kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder");
    CFStringRef *requireKey =
        (CFStringRef *)wk_vt_sym("kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder");
    if (!descCreate || !sessionCreate || !sessionInvalidate || !enableKey || !requireKey)
        return WK_VT_HW_ABSENT;

    WKCMFormatDescriptionRef desc = NULL;
    if (descCreate(kCFAllocatorDefault, codecType, 1920, 1080, NULL, &desc) != noErr || !desc)
        return WK_VT_HW_ABSENT;

    const void *keys[] = { *enableKey, *requireKey };
    const void *values[] = { kCFBooleanTrue, kCFBooleanTrue };
    CFDictionaryRef spec = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    WKVTDecompressionOutputCallbackRecord callback = { wk_vt_probe_output, NULL };
    WKVTDecompressionSessionRef session = NULL;
    OSStatus status = sessionCreate(kCFAllocatorDefault, desc, spec, NULL, &callback, &session);
    if (session) {
        sessionInvalidate(session);
        CFRelease(session);
    }
    if (spec)
        CFRelease(spec);
    CFRelease(desc);

    if (status == noErr)
        return WK_VT_HW_PRESENT;
    if (status == WK_VT_COULD_NOT_FIND_VIDEO_DECODER
        || status == WK_VT_COULD_NOT_FIND_VIDEO_DECODER_LEGACY)
        return WK_VT_HW_ABSENT;
    return WK_VT_HW_UNDETERMINED;
}

Boolean VTIsHardwareDecodeSupported(uint32_t codecType)
{
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static struct { uint32_t codecType; Boolean supported; } cache[16];
    static unsigned cached;

    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < cached; i++) {
        if (cache[i].codecType == codecType) {
            Boolean supported = cache[i].supported;
            pthread_mutex_unlock(&lock);
            return supported;
        }
    }
    pthread_mutex_unlock(&lock);

    WKVTHardwareAnswer answer = wk_vt_probe_hardware_decode(codecType);
    /* A decoder that could not open this instant is still a decoder the machine has, and the
     * next caller asks again. */
    if (answer == WK_VT_HW_UNDETERMINED)
        return true;

    Boolean supported = (answer == WK_VT_HW_PRESENT);

    pthread_mutex_lock(&lock);
    if (cached < sizeof(cache) / sizeof(cache[0]))
        cache[cached++] = (__typeof__(cache[0])){ codecType, supported };
    pthread_mutex_unlock(&lock);
    return supported;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(VTIsHardwareDecodeSupported, "VideoToolbox",
    &VTIsHardwareDecodeSupported, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
