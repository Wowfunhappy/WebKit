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
 * A 32ARGB/32BGRA frame that carries no colour data is encoded from Y'CbCr the frame is first converted
 * to with the session's YCbCrMatrix, else the matrix VideoToolbox assumes for untagged video of the
 * session's size (wk_ycbcr.h), and tagged with that matrix and the session's ColorPrimaries and
 * TransferFunction. 10.9's encoder converts such a frame with BT.601 at every size, and emits nothing for
 * it once the session names a colour property; its BT.601 conversion is kept for a session that names
 * none at a BT.601 size.
 *
 * A specification requiring kVTVideoEncoderSpecification_RequiredLowLatency (10.13+, which libwebrtc's
 * RTCVideoEncoderH264 passes) gets 10.9's own request for a low-latency encoder, kVTVideoEncoderSpecification_Usage
 * 1. Without it the software H.264 encoder holds ten frames before emitting one (333 ms at 30 fps); with it each
 * frame is emitted as it is submitted. Under that usage the encoder writes Constrained Baseline syntax whatever
 * profile is asked for (CAVLC, P and I slices in order, no weighted prediction, slice groups or redundant
 * pictures) but labels it Main. A frame submitted while the session's ProfileLevel is a Baseline one is handed back
 * with a format description whose sequence parameter sets say profile_idc 66 with constraint_set0_flag, as asked,
 * when its parameter sets and its own slices bear that out; a session whose encoder writes a sample they do not
 * keeps the encoder's labels from then on.
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
#include "wk_ycbcr.h"

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
typedef CFTypeID (*WKCVPixelBufferGetTypeIDFunction)(void);
typedef uint32_t (*WKCVPixelBufferGetPixelFormatTypeFunction)(CFTypeRef);
typedef size_t (*WKCVPixelBufferGetWidthFunction)(CFTypeRef);
typedef size_t (*WKCVPixelBufferGetHeightFunction)(CFTypeRef);
typedef CFTypeRef (*WKCVBufferGetAttachmentFunction)(CFTypeRef, CFStringRef, uint32_t *);
typedef void (*WKCVBufferSetAttachmentFunction)(CFTypeRef, CFStringRef, CFTypeRef, uint32_t);
typedef int32_t (*WKCVPixelBufferLockBaseAddressFunction)(CFTypeRef, uint64_t);
typedef int32_t (*WKCVPixelBufferUnlockBaseAddressFunction)(CFTypeRef, uint64_t);
typedef void *(*WKCVPixelBufferGetBaseAddressFunction)(CFTypeRef);
typedef size_t (*WKCVPixelBufferGetBytesPerRowFunction)(CFTypeRef);
typedef void *(*WKCVPixelBufferGetBaseAddressOfPlaneFunction)(CFTypeRef, size_t);
typedef size_t (*WKCVPixelBufferGetBytesPerRowOfPlaneFunction)(CFTypeRef, size_t);
typedef int32_t (*WKCVPixelBufferPoolCreateFunction)(CFAllocatorRef, CFDictionaryRef, CFDictionaryRef, CFTypeRef *);
typedef int32_t (*WKCVPixelBufferPoolCreatePixelBufferFunction)(CFAllocatorRef, CFTypeRef, CFTypeRef *);
typedef OSStatus (*WKVTSessionCopyPropertyFunction)(CFTypeRef, CFStringRef, CFAllocatorRef, void *);
typedef struct WKOpaqueCMFormatDescription *WKCMFormatDescriptionRef;
typedef struct WKOpaqueCMBlockBuffer *WKCMBlockBufferRef;
typedef struct {
    int32_t width;
    int32_t height;
} WKCMVideoDimensions;
typedef WKCMFormatDescriptionRef (*WKCMSampleBufferGetFormatDescriptionFunction)(WKCMSampleBufferRef);
typedef WKCMBlockBufferRef (*WKCMSampleBufferGetDataBufferFunction)(WKCMSampleBufferRef);
typedef CFIndex (*WKCMSampleBufferGetNumSamplesFunction)(WKCMSampleBufferRef);
typedef OSStatus (*WKCMSampleBufferGetSampleSizeArrayFunction)(WKCMSampleBufferRef, CFIndex, size_t *, CFIndex *);
typedef CFArrayRef (*WKCMSampleBufferGetSampleAttachmentsArrayFunction)(WKCMSampleBufferRef, Boolean);
typedef OSStatus (*WKCMSampleBufferCreateFunction)(CFAllocatorRef, WKCMBlockBufferRef, Boolean, void *, void *,
    WKCMFormatDescriptionRef, CFIndex, CFIndex, const WKCMSampleTimingInfo *, CFIndex, const size_t *, WKCMSampleBufferRef *);
typedef CFDictionaryRef (*WKCMCopyDictionaryOfAttachmentsFunction)(CFAllocatorRef, CFTypeRef, uint32_t);
typedef void (*WKCMSetAttachmentsFunction)(CFTypeRef, CFDictionaryRef, uint32_t);
typedef CFDictionaryRef (*WKCMFormatDescriptionGetExtensionsFunction)(WKCMFormatDescriptionRef);
typedef uint32_t (*WKCMFormatDescriptionGetMediaSubTypeFunction)(WKCMFormatDescriptionRef);
typedef WKCMVideoDimensions (*WKCMVideoFormatDescriptionGetDimensionsFunction)(WKCMFormatDescriptionRef);
typedef OSStatus (*WKCMVideoFormatDescriptionCreateFunction)(CFAllocatorRef, uint32_t, int32_t, int32_t, CFDictionaryRef,
    WKCMFormatDescriptionRef *);
typedef size_t (*WKCMBlockBufferGetDataLengthFunction)(WKCMBlockBufferRef);
typedef OSStatus (*WKCMBlockBufferCopyDataBytesFunction)(WKCMBlockBufferRef, size_t, size_t, void *);

static const char kWKVideoToolboxImage[] = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox";
static const char kWKCoreMediaImage[] = "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia";
static const char kWKObjCImage[] = "/usr/lib/libobjc.A.dylib";
static const char kWKCoreVideoImage[] = "/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo";

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
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetFormatDescription)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetDataBuffer)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetNumSamples)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleSizeArray)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleAttachmentsArray)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSampleBufferCreate)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMCopyDictionaryOfAttachments)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMSetAttachments)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMFormatDescriptionGetExtensions)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMFormatDescriptionGetMediaSubType)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMVideoFormatDescriptionGetDimensions)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMVideoFormatDescriptionCreate)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMBlockBufferGetDataLength)
WK_CADENCE_FUNCTION(kWKCoreMediaImage, CMBlockBufferCopyDataBytes)

WK_CADENCE_FUNCTION(kWKObjCImage, objc_getAssociatedObject)
WK_CADENCE_FUNCTION(kWKObjCImage, objc_setAssociatedObject)
WK_CADENCE_FUNCTION(kWKObjCImage, sel_registerName)

WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetTypeID)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetPixelFormatType)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetWidth)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetHeight)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVBufferGetAttachment)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVBufferSetAttachment)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferLockBaseAddress)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferUnlockBaseAddress)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetBaseAddress)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetBytesPerRow)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetBaseAddressOfPlane)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferGetBytesPerRowOfPlane)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferPoolCreate)
WK_CADENCE_FUNCTION(kWKCoreVideoImage, CVPixelBufferPoolCreatePixelBuffer)

WK_CADENCE_FUNCTION(kWKVideoToolboxImage, VTSessionCopyProperty)

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
    int baselineRequested;
} WKCadenceFrame;

typedef struct {
    os_unfair_lock lock;
    WKVTCompressionOutputCallback outputCallback;
    void *outputCallbackRefCon;
    WKCMTime firstPresentationTime;
    int64_t frameCount;
    WKCadenceFrame outstanding;
    int32_t width;
    int32_t height;
    CFTypeRef conversionPool;
    size_t conversionPoolWidth;
    size_t conversionPoolHeight;
    WKCMFormatDescriptionRef encodedFormat;
    WKCMFormatDescriptionRef baselineFormat;
    unsigned nalLengthSize;
    int baselineRefused;
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
    if (session->conversionPool)
        CFRelease(session->conversionPool);
    if (session->encodedFormat)
        CFRelease(session->encodedFormat);
    if (session->baselineFormat)
        CFRelease(session->baselineFormat);
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

typedef struct {
    uint8_t bytes[256];
    size_t length;
    size_t position;
    int overrun;
} WKRBSPReader;

// The RBSP of a NAL unit after its header byte, without emulation-prevention bytes.
static int wk_rbsp_load(WKRBSPReader *reader, const uint8_t *unit, size_t length)
{
    reader->length = 0;
    reader->position = 0;
    reader->overrun = 0;
    unsigned zeros = 0;
    for (size_t i = 1; i < length; ++i) {
        if (zeros == 2 && unit[i] == 3) {
            zeros = 0;
            continue;
        }
        if (reader->length == sizeof(reader->bytes))
            return 0;
        reader->bytes[reader->length++] = unit[i];
        zeros = unit[i] ? 0 : zeros + 1;
    }
    return 1;
}

static uint32_t wk_rbsp_bits(WKRBSPReader *reader, unsigned count)
{
    uint32_t value = 0;
    while (count--) {
        if (reader->position >= reader->length * 8) {
            reader->overrun = 1;
            return 0;
        }
        value = (value << 1) | ((reader->bytes[reader->position / 8] >> (7 - reader->position % 8)) & 1);
        ++reader->position;
    }
    return value;
}

static uint32_t wk_rbsp_ue(WKRBSPReader *reader)
{
    unsigned zeros = 0;
    while (!wk_rbsp_bits(reader, 1)) {
        if (reader->overrun || ++zeros > 31) {
            reader->overrun = 1;
            return 0;
        }
    }
    return (uint32_t)((1ull << zeros) - 1) + wk_rbsp_bits(reader, zeros);
}

// Whether a profile_idc 77 sequence parameter set describes frames only, which Constrained Baseline requires.
static int wk_h264_sps_is_baseline(const uint8_t *unit, size_t length)
{
    WKRBSPReader reader;
    if (length < 4 || unit[1] != 77 || !wk_rbsp_load(&reader, unit, length))
        return 0;
    wk_rbsp_bits(&reader, 24); // profile_idc, constraint flags, level_idc
    wk_rbsp_ue(&reader); // seq_parameter_set_id
    wk_rbsp_ue(&reader); // log2_max_frame_num_minus4
    uint32_t pictureOrderCountType = wk_rbsp_ue(&reader);
    if (!pictureOrderCountType)
        wk_rbsp_ue(&reader);
    else if (pictureOrderCountType == 1) {
        wk_rbsp_bits(&reader, 1);
        wk_rbsp_ue(&reader);
        wk_rbsp_ue(&reader);
        for (uint32_t cycle = wk_rbsp_ue(&reader); cycle && !reader.overrun; --cycle)
            wk_rbsp_ue(&reader);
    }
    wk_rbsp_ue(&reader); // max_num_ref_frames
    wk_rbsp_bits(&reader, 1); // gaps_in_frame_num_value_allowed_flag
    wk_rbsp_ue(&reader); // pic_width_in_mbs_minus1
    wk_rbsp_ue(&reader); // pic_height_in_map_units_minus1
    uint32_t frameMacroblocksOnly = wk_rbsp_bits(&reader, 1);
    return !reader.overrun && frameMacroblocksOnly;
}

// Whether a picture parameter set uses none of the tools Constrained Baseline excludes: CABAC, slice groups,
// weighted prediction, redundant pictures, and the High profiles' 8x8 transform and scaling-matrix extension.
static int wk_h264_pps_is_baseline(const uint8_t *unit, size_t length)
{
    WKRBSPReader reader;
    if (!wk_rbsp_load(&reader, unit, length))
        return 0;
    wk_rbsp_ue(&reader); // pic_parameter_set_id
    wk_rbsp_ue(&reader); // seq_parameter_set_id
    uint32_t entropyCodingMode = wk_rbsp_bits(&reader, 1);
    wk_rbsp_bits(&reader, 1); // bottom_field_pic_order_in_frame_present_flag
    uint32_t sliceGroupsMinus1 = wk_rbsp_ue(&reader);
    wk_rbsp_ue(&reader); // num_ref_idx_l0_default_active_minus1
    wk_rbsp_ue(&reader); // num_ref_idx_l1_default_active_minus1
    uint32_t weightedPrediction = wk_rbsp_bits(&reader, 3);
    wk_rbsp_ue(&reader); // pic_init_qp_minus26
    wk_rbsp_ue(&reader); // pic_init_qs_minus26
    wk_rbsp_ue(&reader); // chroma_qp_index_offset
    wk_rbsp_bits(&reader, 2); // deblocking_filter_control_present_flag, constrained_intra_pred_flag
    uint32_t redundantPictures = wk_rbsp_bits(&reader, 1);
    if (reader.overrun || entropyCodingMode || sliceGroupsMinus1 || weightedPrediction || redundantPictures)
        return 0;
    // Only the rbsp_stop_one_bit and its alignment zeros may follow.
    if (wk_rbsp_bits(&reader, 1) != 1 || reader.overrun)
        return 0;
    while (reader.position < reader.length * 8) {
        if (wk_rbsp_bits(&reader, 1))
            return 0;
    }
    return 1;
}

// A copy of an H.264 format description that labels its sequence parameter sets Constrained Baseline, or NULL when
// they are not profile_idc 77 or a parameter set uses a tool Constrained Baseline excludes.
static WKCMFormatDescriptionRef wk_h264_copy_baseline_format(WKCMFormatDescriptionRef format, unsigned *nalLengthSize)
{
    enum { kAVC1 = 0x61766331 };
    if (!format || wk_system_CMFormatDescriptionGetMediaSubType()(format) != kAVC1)
        return NULL;
    CFDictionaryRef extensions = wk_system_CMFormatDescriptionGetExtensions()(format);
    CFDictionaryRef atoms = extensions ? CFDictionaryGetValue(extensions, CFSTR("SampleDescriptionExtensionAtoms")) : NULL;
    CFDataRef record = atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
    if (!record || CFGetTypeID(record) != CFDataGetTypeID())
        return NULL;

    CFIndex recordLength = CFDataGetLength(record);
    const uint8_t *bytes = CFDataGetBytePtr(record);
    if (recordLength < 7 || bytes[1] != 77)
        return NULL;
    *nalLengthSize = (bytes[4] & 3) + 1;
    CFMutableDataRef relabeled = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, record);
    if (!relabeled)
        return NULL;
    uint8_t *relabeledBytes = CFDataGetMutableBytePtr(relabeled);
    CFIndex offset = 5;
    int conforms = 1;
    for (int array = 0; array < 2 && conforms; ++array) {
        if (offset >= recordLength) {
            conforms = 0;
            break;
        }
        unsigned count = array ? bytes[offset] : (bytes[offset] & 0x1f);
        ++offset;
        for (unsigned i = 0; i < count && conforms; ++i) {
            if (offset + 2 > recordLength) {
                conforms = 0;
                break;
            }
            size_t length = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
            offset += 2;
            if (!length || offset + (CFIndex)length > recordLength) {
                conforms = 0;
                break;
            }
            const uint8_t *unit = bytes + offset;
            if (array) {
                conforms = (unit[0] & 0x1f) == 8 && wk_h264_pps_is_baseline(unit, length);
            } else {
                conforms = (unit[0] & 0x1f) == 7 && wk_h264_sps_is_baseline(unit, length);
                // profile_idc 66 with constraint_set0_flag (Baseline) kept alongside the encoder's own flags.
                // The bytes stay non-zero, so no emulation-prevention byte is gained or lost.
                relabeledBytes[offset + 1] = 66;
                relabeledBytes[offset + 2] |= 0x80;
            }
            offset += (CFIndex)length;
        }
    }
    if (!conforms) {
        CFRelease(relabeled);
        return NULL;
    }
    relabeledBytes[1] = 66;
    relabeledBytes[2] |= 0x80;

    CFMutableDictionaryRef relabeledAtoms = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, atoms);
    CFMutableDictionaryRef relabeledExtensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, extensions);
    WKCMFormatDescriptionRef baselineFormat = NULL;
    if (relabeledAtoms && relabeledExtensions) {
        CFDictionarySetValue(relabeledAtoms, CFSTR("avcC"), relabeled);
        CFDictionarySetValue(relabeledExtensions, CFSTR("SampleDescriptionExtensionAtoms"), relabeledAtoms);
        WKCMVideoDimensions dimensions = wk_system_CMVideoFormatDescriptionGetDimensions()(format);
        if (wk_system_CMVideoFormatDescriptionCreate()(kCFAllocatorDefault, kAVC1, dimensions.width, dimensions.height, relabeledExtensions, &baselineFormat))
            baselineFormat = NULL;
    }
    if (relabeledExtensions)
        CFRelease(relabeledExtensions);
    if (relabeledAtoms)
        CFRelease(relabeledAtoms);
    CFRelease(relabeled);
    return baselineFormat;
}

// Whether an encoded sample holds nothing Constrained Baseline excludes that its parameter sets cannot rule out:
// only non-B, non-switching slices, and no parameter sets of its own.
static int wk_h264_sample_is_baseline(WKCMSampleBufferRef sampleBuffer, unsigned nalLengthSize)
{
    WKCMBlockBufferRef data = wk_system_CMSampleBufferGetDataBuffer()(sampleBuffer);
    size_t length = data ? wk_system_CMBlockBufferGetDataLength()(data) : 0;
    size_t offset = 0;
    while (offset < length) {
        uint8_t prefix[4];
        if (offset + nalLengthSize > length || wk_system_CMBlockBufferCopyDataBytes()(data, offset, nalLengthSize, prefix))
            return 0;
        size_t unitLength = 0;
        for (unsigned i = 0; i < nalLengthSize; ++i)
            unitLength = (unitLength << 8) | prefix[i];
        offset += nalLengthSize;
        if (!unitLength || unitLength > length - offset)
            return 0;
        uint8_t unit[24];
        size_t headerLength = unitLength < sizeof(unit) ? unitLength : sizeof(unit);
        if (wk_system_CMBlockBufferCopyDataBytes()(data, offset, headerLength, unit))
            return 0;
        switch (unit[0] & 0x1f) {
        case 1:
        case 5: {
            WKRBSPReader reader;
            wk_rbsp_load(&reader, unit, headerLength);
            wk_rbsp_ue(&reader); // first_mb_in_slice
            uint32_t sliceType = wk_rbsp_ue(&reader) % 5;
            // P and I; B, SP and SI are outside Constrained Baseline.
            if (reader.overrun || (sliceType != 0 && sliceType != 2))
                return 0;
            break;
        }
        case 2: // Data partitions.
        case 3:
        case 4:
        case 7: // In-band parameter sets.
        case 8:
            return 0;
        default:
            break;
        }
        offset += unitLength;
    }
    return 1;
}

// The format a sample is handed back with when the caller asked for a Baseline profile: its Constrained Baseline
// label, retained, or NULL to keep the sample's own. A session whose encoder writes a sample the label would not
// describe keeps the encoder's labels from then on.
static WKCMFormatDescriptionRef wk_cadence_copy_delivered_format(WKCadenceSession *session, WKCMSampleBufferRef sampleBuffer)
{
    WKCMFormatDescriptionRef format = wk_system_CMSampleBufferGetFormatDescription()(sampleBuffer);
    if (!format)
        return NULL;
    os_unfair_lock_lock(&session->lock);
    if (session->baselineRefused) {
        os_unfair_lock_unlock(&session->lock);
        return NULL;
    }
    WKCMFormatDescriptionRef baselineFormat = NULL;
    unsigned nalLengthSize = session->nalLengthSize;
    int known = session->encodedFormat && CFEqual(format, session->encodedFormat);
    if (known && session->baselineFormat)
        baselineFormat = (WKCMFormatDescriptionRef)CFRetain(session->baselineFormat);
    os_unfair_lock_unlock(&session->lock);

    if (!known) {
        baselineFormat = wk_h264_copy_baseline_format(format, &nalLengthSize);
        os_unfair_lock_lock(&session->lock);
        if (session->encodedFormat)
            CFRelease(session->encodedFormat);
        if (session->baselineFormat)
            CFRelease(session->baselineFormat);
        session->encodedFormat = (WKCMFormatDescriptionRef)CFRetain(format);
        session->baselineFormat = baselineFormat ? (WKCMFormatDescriptionRef)CFRetain(baselineFormat) : NULL;
        session->nalLengthSize = nalLengthSize;
        os_unfair_lock_unlock(&session->lock);
    }
    if (baselineFormat && !wk_h264_sample_is_baseline(sampleBuffer, nalLengthSize)) {
        CFRelease(baselineFormat);
        baselineFormat = NULL;
        os_unfair_lock_lock(&session->lock);
        session->baselineRefused = 1;
        os_unfair_lock_unlock(&session->lock);
    }
    return baselineFormat;
}

static void wk_cadence_copy_attachment(const void *key, const void *value, void *context)
{
    CFDictionarySetValue(context, key, value);
}

// |sampleBuffer| with |format| in place of its own and |timing| in place of its own, its data and attachments shared.
static WKCMSampleBufferRef wk_cadence_copy_sample(WKCMSampleBufferRef sampleBuffer, WKCMFormatDescriptionRef format,
    CFIndex timingCount, const WKCMSampleTimingInfo *timing)
{
    CFIndex sampleCount = wk_system_CMSampleBufferGetNumSamples()(sampleBuffer);
    CFIndex sizeCount = 0;
    if (wk_system_CMSampleBufferGetSampleSizeArray()(sampleBuffer, 0, NULL, &sizeCount))
        sizeCount = 0;
    size_t *sizes = sizeCount ? malloc((size_t)sizeCount * sizeof(*sizes)) : NULL;
    if (sizeCount && (!sizes || wk_system_CMSampleBufferGetSampleSizeArray()(sampleBuffer, sizeCount, sizes, &sizeCount)))
        wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample's sizes did not read");

    WKCMSampleBufferRef copy = NULL;
    if (wk_system_CMSampleBufferCreate()(kCFAllocatorDefault, wk_system_CMSampleBufferGetDataBuffer()(sampleBuffer), true, NULL, NULL,
        format, sampleCount, timingCount, timing, sizeCount, sizes, &copy) || !copy)
        wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample did not copy");
    free(sizes);

    CFArrayRef attachments = wk_system_CMSampleBufferGetSampleAttachmentsArray()(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments)) {
        CFArrayRef copiedAttachments = wk_system_CMSampleBufferGetSampleAttachmentsArray()(copy, true);
        CFIndex count = copiedAttachments ? CFArrayGetCount(copiedAttachments) : 0;
        for (CFIndex i = 0; i < count && i < CFArrayGetCount(attachments); ++i)
            CFDictionaryApplyFunction(CFArrayGetValueAtIndex(attachments, i), wk_cadence_copy_attachment, (void *)CFArrayGetValueAtIndex(copiedAttachments, i));
    }
    for (uint32_t mode = 0; mode < 2; ++mode) { // kCMAttachmentMode_ShouldNotPropagate, kCMAttachmentMode_ShouldPropagate
        CFDictionaryRef bufferAttachments = wk_system_CMCopyDictionaryOfAttachments()(kCFAllocatorDefault, sampleBuffer, mode);
        if (bufferAttachments) {
            wk_system_CMSetAttachments()(copy, bufferAttachments, mode);
            CFRelease(bufferAttachments);
        }
    }
    return copy;
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
    int baselineRequested = frame->baselineRequested;
    free(frame);

    WKCMSampleBufferRef delivered = sampleBuffer;
    WKCMFormatDescriptionRef baselineFormat = baselineRequested && sampleBuffer ? wk_cadence_copy_delivered_format(session, sampleBuffer) : NULL;
    CFIndex count = 0;
    if (sampleBuffer && (durationSupplied || baselineFormat)) {
        if (wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, 0, NULL, &count))
            count = 0;
        WKCMSampleTimingInfo *timing = count > 0 ? malloc((size_t)count * sizeof(*timing)) : NULL;
        if (count > 0 && (!timing || wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, count, timing, &count)))
            wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample's timing did not read");
        if (durationSupplied) {
            for (CFIndex i = 0; i < count; ++i)
                timing[i].duration = (WKCMTime) { 0, 0, 0, 0 };
        }
        if (baselineFormat)
            delivered = wk_cadence_copy_sample(sampleBuffer, baselineFormat, count, timing);
        else if (count > 0) {
            delivered = NULL;
            if (wk_system_CMSampleBufferCreateCopyWithNewTiming()(kCFAllocatorDefault, sampleBuffer, count, timing, &delivered) || !delivered)
                wk_patch_fail("VTCompressionSessionEncodeFrame", "an encoded sample did not copy");
        }
        free(timing);
    }
    if (baselineFormat)
        CFRelease(baselineFormat);
    session->outputCallback(session->outputCallbackRefCon, callerRefCon, status, infoFlags, delivered);
    if (delivered != sampleBuffer)
        CFRelease(delivered);
}

// A copy of an encoder specification requiring kVTVideoEncoderSpecification_RequiredLowLatency (10.13+) that asks
// 10.9 for the same thing: kVTVideoEncoderSpecification_Usage 1, the value 10.9's conferencing stack
// (AVConference's Encoder.c) passes, under which the encoder emits each frame as it is submitted. NULL when the
// specification does not require low latency or already names a usage.
static CFMutableDictionaryRef wk_encode_copy_low_latency_specification(CFDictionaryRef encoderSpecification)
{
    if (!encoderSpecification || CFDictionaryContainsKey(encoderSpecification, CFSTR("EncoderUsage")))
        return NULL;
    CFTypeRef required = CFDictionaryGetValue(encoderSpecification, CFSTR("RequiredLowLatency"));
    if (!required || CFGetTypeID(required) != CFBooleanGetTypeID() || !CFBooleanGetValue(required))
        return NULL;
    CFMutableDictionaryRef specification = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, encoderSpecification);
    int32_t usage = 1;
    CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    if (!specification || !usageNumber)
        wk_patch_fail("VTCompressionSessionCreate", "no memory for the low-latency encoder specification");
    CFDictionarySetValue(specification, CFSTR("EncoderUsage"), usageNumber);
    CFRelease(usageNumber);
    return specification;
}

OSStatus VTCompressionSessionCreate(CFAllocatorRef allocator, int32_t width, int32_t height, uint32_t codecType,
    CFDictionaryRef encoderSpecification, CFDictionaryRef sourceImageBufferAttributes,
    CFAllocatorRef compressedDataAllocator, WKVTCompressionOutputCallback outputCallback,
    void *outputCallbackRefCon, WKVTCompressionSessionRef *compressionSessionOut)
{
    CFMutableDictionaryRef lowLatencySpecification = wk_encode_copy_low_latency_specification(encoderSpecification);
    if (lowLatencySpecification)
        encoderSpecification = lowLatencySpecification;
    if (!outputCallback) {
        OSStatus status = wk_system_VTCompressionSessionCreate()(allocator, width, height, codecType, encoderSpecification,
            sourceImageBufferAttributes, compressedDataAllocator, outputCallback, outputCallbackRefCon, compressionSessionOut);
        if (lowLatencySpecification)
            CFRelease(lowLatencySpecification);
        return status;
    }

    WKCadenceSession *session = calloc(1, sizeof(*session));
    if (!session)
        wk_patch_fail("VTCompressionSessionCreate", "no memory for the session's cadence");
    session->lock = OS_UNFAIR_LOCK_INIT;
    session->outputCallback = outputCallback;
    session->outputCallbackRefCon = outputCallbackRefCon;
    session->outstanding.previous = &session->outstanding;
    session->outstanding.next = &session->outstanding;
    session->width = width;
    session->height = height;

    OSStatus status = wk_system_VTCompressionSessionCreate()(allocator, width, height, codecType, encoderSpecification,
        sourceImageBufferAttributes, compressedDataAllocator, wk_cadence_output, session, compressionSessionOut);
    if (lowLatencySpecification)
        CFRelease(lowLatencySpecification);
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

static CFTypeRef wk_encode_copy_session_string(WKVTCompressionSessionRef compressionSession, CFStringRef key)
{
    CFTypeRef value = NULL;
    if (wk_system_VTSessionCopyProperty()(compressionSession, key, kCFAllocatorDefault, &value) || !value)
        return NULL;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return NULL;
    }
    return value;
}

// A 420v copy of an R'G'B' frame that carries no colour data, converted and tagged as the session's colour
// properties or its size's default matrix say, or NULL for a frame the encoder takes as it is. |*failed| is
// set when the frame needs converting and no buffer could be allocated for it.
static CFTypeRef wk_encode_copy_converted_frame(WKVTCompressionSessionRef compressionSession, WKCadenceSession *session, CFTypeRef imageBuffer, bool *failed)
{
    *failed = false;
    enum { k32ARGB = 0x00000020, k32BGRA = 0x42475241, k420v = 0x34323076 };
    if (!imageBuffer || CFGetTypeID(imageBuffer) != wk_system_CVPixelBufferGetTypeID()())
        return NULL;
    uint32_t format = wk_system_CVPixelBufferGetPixelFormatType()(imageBuffer);
    if (format != k32ARGB && format != k32BGRA)
        return NULL;
    CFStringRef colorKeys[] = { CFSTR("CGColorSpace"), CFSTR("CVImageBufferICCProfile"), CFSTR("CVImageBufferColorPrimaries"), CFSTR("CVImageBufferTransferFunction") };
    for (size_t i = 0; i < sizeof(colorKeys) / sizeof(colorKeys[0]); ++i) {
        if (wk_system_CVBufferGetAttachment()(imageBuffer, colorKeys[i], NULL))
            return NULL;
    }

    CFTypeRef sessionMatrix = wk_encode_copy_session_string(compressionSession, CFSTR("YCbCrMatrix"));
    CFTypeRef sessionPrimaries = wk_encode_copy_session_string(compressionSession, CFSTR("ColorPrimaries"));
    CFTypeRef sessionTransfer = wk_encode_copy_session_string(compressionSession, CFSTR("TransferFunction"));
    CFStringRef matrix = sessionMatrix ? (CFStringRef)sessionMatrix : wk_ycbcr_default_matrix((size_t)session->width, (size_t)session->height);
    const int32_t *coefficients = wk_ycbcr_coefficients(matrix, false);
    bool sessionNamesColor = sessionMatrix || sessionPrimaries || sessionTransfer;

    CFTypeRef converted = NULL;
    if (coefficients && (sessionNamesColor || !CFEqual(matrix, CFSTR("ITU_R_601_4")))) {
        size_t width = wk_system_CVPixelBufferGetWidth()(imageBuffer);
        size_t height = wk_system_CVPixelBufferGetHeight()(imageBuffer);
        os_unfair_lock_lock(&session->lock);
        if (!session->conversionPool || session->conversionPoolWidth != width || session->conversionPoolHeight != height) {
            if (session->conversionPool)
                CFRelease(session->conversionPool);
            session->conversionPool = NULL;
            int32_t pixelFormat = k420v;
            int64_t poolWidth = (int64_t)width, poolHeight = (int64_t)height;
            CFNumberRef formatNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
            CFNumberRef widthNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &poolWidth);
            CFNumberRef heightNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &poolHeight);
            CFDictionaryRef ioSurfaceProperties = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            const void *keys[] = { CFSTR("PixelFormatType"), CFSTR("Width"), CFSTR("Height"), CFSTR("IOSurfaceProperties") };
            const void *values[] = { formatNumber, widthNumber, heightNumber, ioSurfaceProperties };
            CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFTypeRef pool = NULL;
            if (attributes && !wk_system_CVPixelBufferPoolCreate()(kCFAllocatorDefault, NULL, attributes, &pool) && pool) {
                session->conversionPool = pool;
                session->conversionPoolWidth = width;
                session->conversionPoolHeight = height;
            }
            if (attributes)
                CFRelease(attributes);
            CFRelease(ioSurfaceProperties);
            CFRelease(heightNumber);
            CFRelease(widthNumber);
            CFRelease(formatNumber);
        }
        CFTypeRef pool = session->conversionPool ? CFRetain(session->conversionPool) : NULL;
        os_unfair_lock_unlock(&session->lock);

        if (pool && !wk_system_CVPixelBufferPoolCreatePixelBuffer()(kCFAllocatorDefault, pool, &converted) && converted) {
            wk_system_CVPixelBufferLockBaseAddress()(imageBuffer, 1 /* kCVPixelBufferLock_ReadOnly */);
            wk_system_CVPixelBufferLockBaseAddress()(converted, 0);
            wk_ycbcr_convert_rgb32(wk_system_CVPixelBufferGetBaseAddress()(imageBuffer), wk_system_CVPixelBufferGetBytesPerRow()(imageBuffer), format == k32ARGB,
                wk_system_CVPixelBufferGetBaseAddressOfPlane()(converted, 0), wk_system_CVPixelBufferGetBytesPerRowOfPlane()(converted, 0),
                wk_system_CVPixelBufferGetBaseAddressOfPlane()(converted, 1), wk_system_CVPixelBufferGetBytesPerRowOfPlane()(converted, 1),
                width, height, coefficients, false);
            wk_system_CVPixelBufferUnlockBaseAddress()(converted, 0);
            wk_system_CVPixelBufferUnlockBaseAddress()(imageBuffer, 1);
            wk_system_CVBufferSetAttachment()(converted, CFSTR("CVImageBufferYCbCrMatrix"), matrix, 1 /* kCVAttachmentMode_ShouldPropagate */);
            if (sessionPrimaries)
                wk_system_CVBufferSetAttachment()(converted, CFSTR("CVImageBufferColorPrimaries"), sessionPrimaries, 1);
            if (sessionTransfer)
                wk_system_CVBufferSetAttachment()(converted, CFSTR("CVImageBufferTransferFunction"), sessionTransfer, 1);
        }
        if (pool)
            CFRelease(pool);
        *failed = !converted;
    }
    if (sessionMatrix)
        CFRelease(sessionMatrix);
    if (sessionPrimaries)
        CFRelease(sessionPrimaries);
    if (sessionTransfer)
        CFRelease(sessionTransfer);
    return converted;
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

    bool conversionFailed;
    CFTypeRef converted = wk_encode_copy_converted_frame(compressionSession, session, imageBuffer, &conversionFailed);
    if (conversionFailed)
        return -12904; // kVTAllocationFailedErr

    WKCadenceFrame *frame = calloc(1, sizeof(*frame));
    if (!frame)
        wk_patch_fail("VTCompressionSessionEncodeFrame", "no memory for a frame's cadence");
    frame->sourceFrameRefCon = sourceFrameRefCon;

    CFTypeRef profileLevel = wk_encode_copy_session_string(compressionSession, CFSTR("ProfileLevel"));
    if (profileLevel) {
        frame->baselineRequested = CFStringHasPrefix(profileLevel, CFSTR("H264_Baseline_"));
        CFRelease(profileLevel);
    }

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

    OSStatus status = wk_system_VTCompressionSessionEncodeFrame()(compressionSession, converted ? converted : imageBuffer,
        presentationTimeStamp, duration, frameProperties, frame, infoFlagsOut);
    if (converted)
        CFRelease(converted);
    return status;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(VTCompressionSessionCreate, "VideoToolbox", &VTCompressionSessionCreate, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(VTCompressionSessionEncodeFrame, "VideoToolbox", &VTCompressionSessionEncodeFrame, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
