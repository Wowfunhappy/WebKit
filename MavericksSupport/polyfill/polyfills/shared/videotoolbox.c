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
 * WK_POLYFILL_REGISTERED is defined only by polyfill/scripts/build-polyfill.sh, i.e. only when
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
typedef struct MavOpaqueCMFormatDescription *MavCMFormatDescriptionRef;
typedef struct MavOpaqueVTDecompressionSession *MavVTDecompressionSessionRef;
typedef void (*MavVTDecompressionOutputCallback)(void *, void *, OSStatus, uint32_t,
    void *, int64_t, int64_t);
typedef struct {
    MavVTDecompressionOutputCallback decompressionOutputCallback;
    void *decompressionOutputRefCon;
} MavVTDecompressionOutputCallbackRecord;

typedef OSStatus (*MavCMVideoFormatDescriptionCreate)(CFAllocatorRef, uint32_t, int32_t,
    int32_t, CFDictionaryRef, MavCMFormatDescriptionRef *);
typedef OSStatus (*MavVTDecompressionSessionCreate)(CFAllocatorRef, MavCMFormatDescriptionRef,
    CFDictionaryRef, CFDictionaryRef, const MavVTDecompressionOutputCallbackRecord *,
    MavVTDecompressionSessionRef *);
typedef void (*MavVTDecompressionSessionInvalidate)(MavVTDecompressionSessionRef);

static void *mav_vt_sym(const char *name)
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

static void *mav_cm_sym(const char *name)
{
    static void *handle;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
        if (!handle)
            return NULL;
    }
    return dlsym(handle, name);
}

static void mav_vt_probe_output(void *refcon, void *sourceRefCon, OSStatus status,
    uint32_t flags, void *imageBuffer, int64_t pts, int64_t duration)
{
    (void)refcon; (void)sourceRefCon; (void)status; (void)flags;
    (void)imageBuffer; (void)pts; (void)duration;
}

/* One RequireHardware session attempt for the codec type. noErr means the machine has a
 * hardware decoder for it; every other outcome -- no such decoder, unknown codec type, a
 * framework that will not load -- is "no hardware decode support", which is what the caller
 * asked about. */
static Boolean mav_vt_probe_hardware_decode(uint32_t codecType)
{
    MavCMVideoFormatDescriptionCreate descCreate =
        (MavCMVideoFormatDescriptionCreate)mav_cm_sym("CMVideoFormatDescriptionCreate");
    MavVTDecompressionSessionCreate sessionCreate =
        (MavVTDecompressionSessionCreate)mav_vt_sym("VTDecompressionSessionCreate");
    MavVTDecompressionSessionInvalidate sessionInvalidate =
        (MavVTDecompressionSessionInvalidate)mav_vt_sym("VTDecompressionSessionInvalidate");
    CFStringRef *enableKey =
        (CFStringRef *)mav_vt_sym("kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder");
    CFStringRef *requireKey =
        (CFStringRef *)mav_vt_sym("kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder");
    if (!descCreate || !sessionCreate || !sessionInvalidate || !enableKey || !requireKey)
        return false;

    MavCMFormatDescriptionRef desc = NULL;
    if (descCreate(kCFAllocatorDefault, codecType, 1920, 1080, NULL, &desc) != noErr || !desc)
        return false;

    const void *keys[] = { *enableKey, *requireKey };
    const void *values[] = { kCFBooleanTrue, kCFBooleanTrue };
    CFDictionaryRef spec = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    MavVTDecompressionOutputCallbackRecord callback = { mav_vt_probe_output, NULL };
    MavVTDecompressionSessionRef session = NULL;
    OSStatus status = sessionCreate(kCFAllocatorDefault, desc, spec, NULL, &callback, &session);
    if (session) {
        sessionInvalidate(session);
        CFRelease(session);
    }
    if (spec)
        CFRelease(spec);
    CFRelease(desc);
    return status == noErr;
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

    Boolean supported = mav_vt_probe_hardware_decode(codecType);

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
