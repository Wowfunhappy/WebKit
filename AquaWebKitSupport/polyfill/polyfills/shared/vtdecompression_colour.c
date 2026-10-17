/*
 * VTDecompressionSessionCreate, VTDecompressionSessionCanAcceptFormatDescription and
 * VTDecompressionSessionDecodeFrame -- DELIBERATE OVERRIDES of functions 10.9 has.
 *
 * 10.9's H.264 decoder accepts a format description only when the colour description in the VUI of
 * its avcC's sequence parameter sets stays within colour_primaries 0-8, transfer_characteristics 0-12
 * and matrix_coefficients 0-8 (measured over 0-255 for each field). Any other value makes every frame
 * fail with -8969 (10.9's kVTVideoDecoderBadDataErr), CMVideoFormatDescriptionCreateFromH264ParameterSets'
 * descriptions included, and VTDecompressionSessionCanAcceptFormatDescription answers false for it.
 * In-band parameter sets do not take part.
 *
 * VUI colour information plays no part in reconstructing samples (H.264 Annex E). A session is created
 * from a copy of the caller's description in which only the out-of-range colour fields of each SPS
 * say unspecified (2); the caller's description is untouched. 10.9 holds each sample buffer's
 * description to the session's (a sample carrying the caller's description fails with
 * kVTFormatDescriptionChangeNotSupportedErr), so a sample whose description has such a copy is decoded
 * as a sample carrying the copy, its data, timing and attachments shared. Whether a session can accept
 * a description is answered for that description's copy.
 *
 * Per-session state lives in an associated object on the session and goes with it. Plain C, with the
 * frameworks' types declared locally and their entry points taken from the loaded images' own symbol
 * tables: deps/build_deps.sh compiles this file into the gap archive force-loaded into every media dylib,
 * and polyfill/build-polyfill.sh compiles it into libpolyfill.a for WebKit, where WK_POLYFILL_REGISTERED
 * adds the registry entries.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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

typedef struct {
    int32_t width;
    int32_t height;
} WKCMVideoDimensions;

typedef struct WKOpaqueVTDecompressionSession *WKVTDecompressionSessionRef;
typedef struct WKOpaqueCMFormatDescription *WKCMFormatDescriptionRef;
typedef struct WKOpaqueCMSampleBuffer *WKCMSampleBufferRef;
typedef struct WKOpaqueCMBlockBuffer *WKCMBlockBufferRef;
typedef struct WKVTDecompressionOutputCallbackRecord WKVTDecompressionOutputCallbackRecord;

typedef OSStatus (*WKVTDecompressionSessionCreateFunction)(CFAllocatorRef, WKCMFormatDescriptionRef, CFDictionaryRef,
    CFDictionaryRef, const WKVTDecompressionOutputCallbackRecord *, WKVTDecompressionSessionRef *);
typedef Boolean (*WKVTDecompressionSessionCanAcceptFormatDescriptionFunction)(WKVTDecompressionSessionRef, WKCMFormatDescriptionRef);
typedef OSStatus (*WKVTDecompressionSessionDecodeFrameFunction)(WKVTDecompressionSessionRef, WKCMSampleBufferRef, uint32_t,
    void *, uint32_t *);
typedef CFDictionaryRef (*WKCMFormatDescriptionGetExtensionsFunction)(WKCMFormatDescriptionRef);
typedef uint32_t (*WKCMFormatDescriptionGetMediaSubTypeFunction)(WKCMFormatDescriptionRef);
typedef WKCMVideoDimensions (*WKCMVideoFormatDescriptionGetDimensionsFunction)(WKCMFormatDescriptionRef);
typedef OSStatus (*WKCMVideoFormatDescriptionCreateFunction)(CFAllocatorRef, uint32_t, int32_t, int32_t, CFDictionaryRef,
    WKCMFormatDescriptionRef *);
typedef WKCMFormatDescriptionRef (*WKCMSampleBufferGetFormatDescriptionFunction)(WKCMSampleBufferRef);
typedef WKCMBlockBufferRef (*WKCMSampleBufferGetDataBufferFunction)(WKCMSampleBufferRef);
typedef Boolean (*WKCMSampleBufferDataIsReadyFunction)(WKCMSampleBufferRef);
typedef OSStatus (*WKCMSampleBufferMakeDataReadyFunction)(WKCMSampleBufferRef);
typedef CFIndex (*WKCMSampleBufferGetNumSamplesFunction)(WKCMSampleBufferRef);
typedef OSStatus (*WKCMSampleBufferGetSampleSizeArrayFunction)(WKCMSampleBufferRef, CFIndex, size_t *, CFIndex *);
typedef OSStatus (*WKCMSampleBufferGetSampleTimingInfoArrayFunction)(WKCMSampleBufferRef, CFIndex, WKCMSampleTimingInfo *, CFIndex *);
typedef CFArrayRef (*WKCMSampleBufferGetSampleAttachmentsArrayFunction)(WKCMSampleBufferRef, Boolean);
typedef OSStatus (*WKCMSampleBufferCreateFunction)(CFAllocatorRef, WKCMBlockBufferRef, Boolean, void *, void *,
    WKCMFormatDescriptionRef, CFIndex, CFIndex, const WKCMSampleTimingInfo *, CFIndex, const size_t *, WKCMSampleBufferRef *);
typedef CFDictionaryRef (*WKCMCopyDictionaryOfAttachmentsFunction)(CFAllocatorRef, CFTypeRef, uint32_t);
typedef void (*WKCMSetAttachmentsFunction)(CFTypeRef, CFDictionaryRef, uint32_t);
typedef void *(*WKobjc_getAssociatedObjectFunction)(const void *, const void *);
typedef void (*WKobjc_setAssociatedObjectFunction)(const void *, const void *, const void *, uintptr_t);
typedef const void *(*WKsel_registerNameFunction)(const char *);

static const char kWKVideoToolboxImage[] = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox";
static const char kWKCoreMediaImage[] = "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia";
static const char kWKObjCImage[] = "/usr/lib/libobjc.A.dylib";

// VideoToolbox's three entry points are the ones this file replaces, so they are taken from the framework's
// own symbol table: dlsym answers a replaced name with the replacement. The rest are asked of dlsym, which
// also runs the resolver 10.9's libobjc exports its association functions through.
static void *wk_vtdecode_image_symbol(void **slot, const char *symbol)
{
    void *address = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!address) {
        wk_image loadedImage;
        if (!wk_find_image(kWKVideoToolboxImage, &loadedImage)) {
            dlopen(kWKVideoToolboxImage, RTLD_LAZY | RTLD_LOCAL);
            wk_find_image(kWKVideoToolboxImage, &loadedImage);
        }
        address = wk_symbol_in_image(&loadedImage, symbol);
        __atomic_store_n(slot, address, __ATOMIC_RELAXED);
    }
    return address;
}

static void *wk_vtdecode_symbol(void **slot, const char *image, const char *symbol)
{
    void *address = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!address) {
        address = dlsym(dlopen(image, RTLD_LAZY | RTLD_LOCAL), symbol);
        __atomic_store_n(slot, address, __ATOMIC_RELAXED);
    }
    return address;
}

#define WK_VTDECODE_SYSTEM_FUNCTION(name) \
    static WK##name##Function wk_system_##name(void) \
    { \
        static void *cached; \
        return (WK##name##Function)wk_vtdecode_image_symbol(&cached, "_" #name); \
    }

#define WK_VTDECODE_FUNCTION(image, name) \
    static WK##name##Function wk_system_##name(void) \
    { \
        static void *cached; \
        return (WK##name##Function)wk_vtdecode_symbol(&cached, image, #name); \
    }

WK_VTDECODE_SYSTEM_FUNCTION(VTDecompressionSessionCreate)
WK_VTDECODE_SYSTEM_FUNCTION(VTDecompressionSessionCanAcceptFormatDescription)
WK_VTDECODE_SYSTEM_FUNCTION(VTDecompressionSessionDecodeFrame)

WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMFormatDescriptionGetExtensions)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMFormatDescriptionGetMediaSubType)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMVideoFormatDescriptionGetDimensions)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMVideoFormatDescriptionCreate)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetFormatDescription)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetDataBuffer)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferDataIsReady)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferMakeDataReady)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetNumSamples)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleSizeArray)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleTimingInfoArray)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferGetSampleAttachmentsArray)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSampleBufferCreate)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMCopyDictionaryOfAttachments)
WK_VTDECODE_FUNCTION(kWKCoreMediaImage, CMSetAttachments)

WK_VTDECODE_FUNCTION(kWKObjCImage, objc_getAssociatedObject)
WK_VTDECODE_FUNCTION(kWKObjCImage, objc_setAssociatedObject)
WK_VTDECODE_FUNCTION(kWKObjCImage, sel_registerName)

// Every image that force-loads this file has its own copy of it, and a session one image creates may be
// decoded from another, so the association key is a registered selector: the same address in every image.
static const void *wk_vtdecode_session_key(void)
{
    static const void *key;
    const void *value = __atomic_load_n(&key, __ATOMIC_RELAXED);
    if (!value) {
        value = wk_system_sel_registerName()("WKVTDecompressionSessionColour");
        __atomic_store_n(&key, value, __ATOMIC_RELAXED);
    }
    return value;
}

// ---- The SPS colour description ----------------------------------------------------------------------

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t position;
} WKSPSReader;

static int wk_sps_bits(WKSPSReader *reader, unsigned count, uint32_t *value)
{
    uint32_t result = 0;
    if (count > 32 || reader->position + count > reader->size * 8)
        return 0;
    while (count--) {
        result = (result << 1) | ((reader->data[reader->position / 8] >> (7 - reader->position % 8)) & 1);
        ++reader->position;
    }
    *value = result;
    return 1;
}

static int wk_sps_ue(WKSPSReader *reader, uint32_t *value)
{
    unsigned zeros = 0;
    uint32_t bit, suffix;
    for (;;) {
        if (!wk_sps_bits(reader, 1, &bit))
            return 0;
        if (bit)
            break;
        if (++zeros > 31)
            return 0;
    }
    if (!wk_sps_bits(reader, zeros, &suffix))
        return 0;
    *value = (uint32_t)((1ull << zeros) - 1 + suffix);
    return 1;
}

static int wk_sps_skip(WKSPSReader *reader, unsigned bits, unsigned ueCount)
{
    uint32_t value;
    if (bits && !wk_sps_bits(reader, bits, &value))
        return 0;
    while (ueCount--) {
        if (!wk_sps_ue(reader, &value))
            return 0;
    }
    return 1;
}

// The bit position of colour_primaries in an SPS RBSP (NAL header included) that carries a VUI colour
// description, following seq_parameter_set_data() and vui_parameters() (ITU-T H.264 7.3.2.1.1, E.1.1).
static int wk_sps_colour_description_position(const uint8_t *rbsp, size_t size, size_t *position)
{
    WKSPSReader reader = { rbsp, size, 0 };
    uint32_t value, profile, chromaFormat = 1, pictureOrderCountType, count;

    // NAL header, profile_idc, constraint flags + level_idc, seq_parameter_set_id
    if (!wk_sps_skip(&reader, 8, 0) || !wk_sps_bits(&reader, 8, &profile) || !wk_sps_skip(&reader, 16, 1))
        return 0;
    switch (profile) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135:
        if (!wk_sps_ue(&reader, &chromaFormat))
            return 0;
        // separate_colour_plane_flag
        if (chromaFormat == 3 && !wk_sps_skip(&reader, 1, 0))
            return 0;
        // bit_depth_luma_minus8, bit_depth_chroma_minus8, qpprime_y_zero_transform_bypass_flag,
        // seq_scaling_matrix_present_flag
        if (!wk_sps_skip(&reader, 0, 2) || !wk_sps_skip(&reader, 1, 0) || !wk_sps_bits(&reader, 1, &value))
            return 0;
        if (!value)
            break;
        for (unsigned list = 0; list < (chromaFormat != 3 ? 8u : 12u); ++list) {
            if (!wk_sps_bits(&reader, 1, &value))
                return 0;
            if (!value)
                continue;
            int lastScale = 8, nextScale = 8;
            for (unsigned j = 0; j < (list < 6 ? 16u : 64u); ++j) {
                if (nextScale) {
                    if (!wk_sps_ue(&reader, &value))
                        return 0;
                    // delta_scale is se(v) in -128..127 (7.4.2.1.1.1): codeNum 0..254 and 256.
                    if (value == 255 || value > 256)
                        return 0;
                    int deltaScale = (value & 1) ? (int)((value + 1) / 2) : -(int)(value / 2);
                    nextScale = (lastScale + deltaScale + 256) % 256;
                }
                if (nextScale)
                    lastScale = nextScale;
            }
        }
        break;
    default:
        break;
    }

    // log2_max_frame_num_minus4, pic_order_cnt_type
    if (!wk_sps_skip(&reader, 0, 1) || !wk_sps_ue(&reader, &pictureOrderCountType))
        return 0;
    if (!pictureOrderCountType) {
        if (!wk_sps_skip(&reader, 0, 1))
            return 0;
    } else if (pictureOrderCountType == 1) {
        // delta_pic_order_always_zero_flag, offset_for_non_ref_pic, offset_for_top_to_bottom_field,
        // num_ref_frames_in_pic_order_cnt_cycle, offset_for_ref_frame[]
        if (!wk_sps_skip(&reader, 1, 2) || !wk_sps_ue(&reader, &count) || count > 255 || !wk_sps_skip(&reader, 0, count))
            return 0;
    }
    // max_num_ref_frames, gaps_in_frame_num_value_allowed_flag, pic_width_in_mbs_minus1,
    // pic_height_in_map_units_minus1, frame_mbs_only_flag
    if (!wk_sps_skip(&reader, 0, 1) || !wk_sps_skip(&reader, 1, 2) || !wk_sps_bits(&reader, 1, &value))
        return 0;
    // mb_adaptive_frame_field_flag
    if (!value && !wk_sps_skip(&reader, 1, 0))
        return 0;
    // direct_8x8_inference_flag, frame_cropping_flag, frame_crop_*_offset
    if (!wk_sps_skip(&reader, 1, 0) || !wk_sps_bits(&reader, 1, &value) || (value && !wk_sps_skip(&reader, 0, 4)))
        return 0;
    // vui_parameters_present_flag, aspect_ratio_info_present_flag
    if (!wk_sps_bits(&reader, 1, &value) || !value || !wk_sps_bits(&reader, 1, &value))
        return 0;
    // aspect_ratio_idc, and sar_width + sar_height for Extended_SAR
    if (value && (!wk_sps_bits(&reader, 8, &value) || (value == 255 && !wk_sps_skip(&reader, 32, 0))))
        return 0;
    // overscan_info_present_flag, overscan_appropriate_flag
    if (!wk_sps_bits(&reader, 1, &value) || (value && !wk_sps_skip(&reader, 1, 0)))
        return 0;
    // video_signal_type_present_flag, video_format, video_full_range_flag, colour_description_present_flag
    if (!wk_sps_bits(&reader, 1, &value) || !value || !wk_sps_skip(&reader, 4, 0) || !wk_sps_bits(&reader, 1, &value) || !value
        || reader.position + 24 > size * 8)
        return 0;
    *position = reader.position;
    return 1;
}

static void wk_sps_write_byte(uint8_t *rbsp, size_t position, uint8_t value)
{
    for (unsigned i = 0; i < 8; ++i, ++position) {
        uint8_t mask = (uint8_t)(1 << (7 - position % 8));
        if ((value >> (7 - i)) & 1)
            rbsp[position / 8] |= mask;
        else
            rbsp[position / 8] &= (uint8_t)~mask;
    }
}

// A copy of an avcC whose SPS colour descriptions stay within the ranges 10.9 accepts, or NULL when the
// record already does or does not parse.
static CFDataRef wk_avcc_copy_in_range(const uint8_t *avcc, size_t size)
{
    static const uint8_t limits[3] = { 8, 12, 8 }; // colour_primaries, transfer_characteristics, matrix_coefficients
    if (size < 7)
        return NULL;
    CFMutableDataRef result = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!result)
        return NULL;
    CFDataAppendBytes(result, avcc, 6);
    unsigned spsCount = avcc[5] & 0x1f;
    size_t offset = 6;
    int changed = 0;
    for (unsigned i = 0; i < spsCount; ++i) {
        if (offset + 2 > size)
            goto invalid;
        size_t unitSize = ((size_t)avcc[offset] << 8) | avcc[offset + 1];
        if (!unitSize || offset + 2 + unitSize > size)
            goto invalid;
        const uint8_t *unit = avcc + offset + 2;

        uint8_t *rbsp = malloc(unitSize);
        if (!rbsp)
            goto invalid;
        size_t rbspSize = 0;
        unsigned zeros = 0;
        for (size_t j = 0; j < unitSize; ++j) {
            if (zeros >= 2 && unit[j] == 3) {
                zeros = 0;
                continue;
            }
            rbsp[rbspSize++] = unit[j];
            zeros = unit[j] ? 0 : zeros + 1;
        }

        int unitChanged = 0;
        size_t position;
        if ((unit[0] & 0x1f) == 7 && wk_sps_colour_description_position(rbsp, rbspSize, &position)) {
            for (unsigned field = 0; field < 3; ++field) {
                WKSPSReader reader = { rbsp, rbspSize, position + field * 8 };
                uint32_t value;
                if (wk_sps_bits(&reader, 8, &value) && value > limits[field]) {
                    wk_sps_write_byte(rbsp, position + field * 8, 2);
                    unitChanged = 1;
                }
            }
        }
        if (!unitChanged) {
            free(rbsp);
            CFDataAppendBytes(result, avcc + offset, (CFIndex)(2 + unitSize));
            offset += 2 + unitSize;
            continue;
        }

        uint8_t *escaped = malloc(rbspSize * 3 / 2 + 2);
        if (!escaped) {
            free(rbsp);
            goto invalid;
        }
        size_t escapedSize = 0;
        zeros = 0;
        for (size_t j = 0; j < rbspSize; ++j) {
            if (zeros >= 2 && rbsp[j] <= 3) {
                escaped[escapedSize++] = 3;
                zeros = 0;
            }
            escaped[escapedSize++] = rbsp[j];
            zeros = rbsp[j] ? 0 : zeros + 1;
        }
        free(rbsp);
        uint8_t length[2] = { (uint8_t)(escapedSize >> 8), (uint8_t)escapedSize };
        CFDataAppendBytes(result, length, 2);
        CFDataAppendBytes(result, escaped, (CFIndex)escapedSize);
        free(escaped);
        offset += 2 + unitSize;
        changed = 1;
    }
    if (!changed)
        goto invalid;
    CFDataAppendBytes(result, avcc + offset, (CFIndex)(size - offset));
    return result;

invalid:
    CFRelease(result);
    return NULL;
}

// A copy of an H.264 format description whose avcC's SPS colour descriptions stay within the ranges 10.9
// accepts, its other extensions kept, or NULL when the description needs none.
static WKCMFormatDescriptionRef wk_format_copy_in_range(WKCMFormatDescriptionRef format)
{
    enum { kAVC1 = 0x61766331 };
    if (!format || wk_system_CMFormatDescriptionGetMediaSubType()(format) != kAVC1)
        return NULL;
    CFDictionaryRef extensions = wk_system_CMFormatDescriptionGetExtensions()(format);
    CFDictionaryRef atoms = extensions ? CFDictionaryGetValue(extensions, CFSTR("SampleDescriptionExtensionAtoms")) : NULL;
    CFDataRef record = atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
    if (!record || CFGetTypeID(record) != CFDataGetTypeID())
        return NULL;
    CFDataRef inRange = wk_avcc_copy_in_range(CFDataGetBytePtr(record), (size_t)CFDataGetLength(record));
    if (!inRange)
        return NULL;

    CFMutableDictionaryRef inRangeAtoms = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, atoms);
    CFMutableDictionaryRef inRangeExtensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, extensions);
    WKCMFormatDescriptionRef copy = NULL;
    if (inRangeAtoms && inRangeExtensions) {
        CFDictionarySetValue(inRangeAtoms, CFSTR("avcC"), inRange);
        CFDictionarySetValue(inRangeExtensions, CFSTR("SampleDescriptionExtensionAtoms"), inRangeAtoms);
        WKCMVideoDimensions dimensions = wk_system_CMVideoFormatDescriptionGetDimensions()(format);
        if (wk_system_CMVideoFormatDescriptionCreate()(kCFAllocatorDefault, kAVC1, dimensions.width, dimensions.height, inRangeExtensions, &copy))
            copy = NULL;
    }
    if (inRangeExtensions)
        CFRelease(inRangeExtensions);
    if (inRangeAtoms)
        CFRelease(inRangeAtoms);
    CFRelease(inRange);
    return copy;
}

// ---- Sessions ------------------------------------------------------------------------------------------

// The session's last-seen sample description and the copy it decodes as (NULL when it needs none).
typedef struct {
    os_unfair_lock lock;
    WKCMFormatDescriptionRef format;
    WKCMFormatDescriptionRef inRangeFormat;
} WKVTDecodeSession;

static void wk_vtdecode_session_free(void *pointer, void *info)
{
    (void)info;
    WKVTDecodeSession *session = pointer;
    if (session->format)
        CFRelease(session->format);
    if (session->inRangeFormat)
        CFRelease(session->inRangeFormat);
    free(session);
}

static CFAllocatorRef wk_vtdecodeSessionDeallocator;

static void wk_vtdecode_create_session_deallocator(void)
{
    CFAllocatorContext context = { 0 };
    context.deallocate = wk_vtdecode_session_free;
    wk_vtdecodeSessionDeallocator = CFAllocatorCreate(kCFAllocatorDefault, &context);
    if (!wk_vtdecodeSessionDeallocator)
        wk_patch_fail("VTDecompressionSessionCreate", "no memory for the session deallocator");
}

static CFAllocatorRef wk_vtdecode_session_deallocator(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_vtdecode_create_session_deallocator);
    return wk_vtdecodeSessionDeallocator;
}

static WKVTDecodeSession *wk_vtdecode_session(WKVTDecompressionSessionRef decompressionSession)
{
    CFDataRef owner = decompressionSession
        ? wk_system_objc_getAssociatedObject()(decompressionSession, wk_vtdecode_session_key()) : NULL;
    return owner ? (WKVTDecodeSession *)CFDataGetBytePtr(owner) : NULL;
}

// The description |format| decodes as in |session|, retained, or NULL when it decodes as itself.
static WKCMFormatDescriptionRef wk_vtdecode_copy_in_range_format(WKVTDecodeSession *session, WKCMFormatDescriptionRef format)
{
    os_unfair_lock_lock(&session->lock);
    if (format == session->format) {
        WKCMFormatDescriptionRef inRangeFormat = session->inRangeFormat ? (WKCMFormatDescriptionRef)CFRetain(session->inRangeFormat) : NULL;
        os_unfair_lock_unlock(&session->lock);
        return inRangeFormat;
    }
    os_unfair_lock_unlock(&session->lock);

    WKCMFormatDescriptionRef inRangeFormat = wk_format_copy_in_range(format);
    os_unfair_lock_lock(&session->lock);
    WKCMFormatDescriptionRef previousFormat = session->format, previousInRangeFormat = session->inRangeFormat;
    session->format = (WKCMFormatDescriptionRef)CFRetain(format);
    session->inRangeFormat = inRangeFormat ? (WKCMFormatDescriptionRef)CFRetain(inRangeFormat) : NULL;
    os_unfair_lock_unlock(&session->lock);
    if (previousFormat)
        CFRelease(previousFormat);
    if (previousInRangeFormat)
        CFRelease(previousInRangeFormat);
    return inRangeFormat;
}

OSStatus VTDecompressionSessionCreate(CFAllocatorRef allocator, WKCMFormatDescriptionRef videoFormatDescription,
    CFDictionaryRef videoDecoderSpecification, CFDictionaryRef destinationImageBufferAttributes,
    const WKVTDecompressionOutputCallbackRecord *outputCallback, WKVTDecompressionSessionRef *decompressionSessionOut)
{
    enum { kAVC1 = 0x61766331 };
    if (!videoFormatDescription || wk_system_CMFormatDescriptionGetMediaSubType()(videoFormatDescription) != kAVC1) {
        return wk_system_VTDecompressionSessionCreate()(allocator, videoFormatDescription, videoDecoderSpecification,
            destinationImageBufferAttributes, outputCallback, decompressionSessionOut);
    }

    WKVTDecodeSession *session = calloc(1, sizeof(*session));
    if (!session)
        wk_patch_fail("VTDecompressionSessionCreate", "no memory for the session's state");
    session->lock = OS_UNFAIR_LOCK_INIT;
    session->format = (WKCMFormatDescriptionRef)CFRetain(videoFormatDescription);
    session->inRangeFormat = wk_format_copy_in_range(videoFormatDescription);

    OSStatus status = wk_system_VTDecompressionSessionCreate()(allocator,
        session->inRangeFormat ? session->inRangeFormat : videoFormatDescription, videoDecoderSpecification,
        destinationImageBufferAttributes, outputCallback, decompressionSessionOut);
    if (status || !decompressionSessionOut || !*decompressionSessionOut) {
        wk_vtdecode_session_free(session, NULL);
        return status;
    }

    CFDataRef owner = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, (const UInt8 *)session, sizeof(*session),
        wk_vtdecode_session_deallocator());
    if (!owner)
        wk_patch_fail("VTDecompressionSessionCreate", "no memory for the session's state owner");
    wk_system_objc_setAssociatedObject()(*decompressionSessionOut, wk_vtdecode_session_key(), owner, 1 /* OBJC_ASSOCIATION_RETAIN_NONATOMIC */);
    CFRelease(owner);
    return status;
}

Boolean VTDecompressionSessionCanAcceptFormatDescription(WKVTDecompressionSessionRef decompressionSession,
    WKCMFormatDescriptionRef newFormatDescription)
{
    WKVTDecodeSession *session = wk_vtdecode_session(decompressionSession);
    WKCMFormatDescriptionRef inRangeFormat = session && newFormatDescription
        ? wk_vtdecode_copy_in_range_format(session, newFormatDescription) : NULL;
    Boolean accepts = wk_system_VTDecompressionSessionCanAcceptFormatDescription()(decompressionSession,
        inRangeFormat ? inRangeFormat : newFormatDescription);
    if (inRangeFormat)
        CFRelease(inRangeFormat);
    return accepts;
}

static void wk_vtdecode_copy_attachment(const void *key, const void *value, void *context)
{
    CFDictionarySetValue(context, key, value);
}

// |sampleBuffer|, whose data is ready, with |format| in place of its own, its data, timing and attachments shared;
// NULL when it does not copy.
static WKCMSampleBufferRef wk_vtdecode_copy_sample(WKCMSampleBufferRef sampleBuffer, WKCMFormatDescriptionRef format)
{
    CFIndex sampleCount = wk_system_CMSampleBufferGetNumSamples()(sampleBuffer);
    CFIndex sizeCount = 0, timingCount = 0;
    if (wk_system_CMSampleBufferGetSampleSizeArray()(sampleBuffer, 0, NULL, &sizeCount))
        sizeCount = 0;
    if (wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, 0, NULL, &timingCount))
        timingCount = 0;
    size_t *sizes = sizeCount ? malloc((size_t)sizeCount * sizeof(*sizes)) : NULL;
    WKCMSampleTimingInfo *timing = timingCount ? malloc((size_t)timingCount * sizeof(*timing)) : NULL;
    WKCMSampleBufferRef copy = NULL;
    if ((!sizeCount || (sizes && !wk_system_CMSampleBufferGetSampleSizeArray()(sampleBuffer, sizeCount, sizes, &sizeCount)))
        && (!timingCount || (timing && !wk_system_CMSampleBufferGetSampleTimingInfoArray()(sampleBuffer, timingCount, timing, &timingCount)))) {
        if (wk_system_CMSampleBufferCreate()(kCFAllocatorDefault, wk_system_CMSampleBufferGetDataBuffer()(sampleBuffer),
            true, NULL, NULL, format, sampleCount, timingCount, timing, sizeCount, sizes, &copy))
            copy = NULL;
    }
    free(sizes);
    free(timing);
    if (!copy)
        return NULL;

    CFArrayRef attachments = wk_system_CMSampleBufferGetSampleAttachmentsArray()(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments)) {
        CFArrayRef copiedAttachments = wk_system_CMSampleBufferGetSampleAttachmentsArray()(copy, true);
        CFIndex count = copiedAttachments ? CFArrayGetCount(copiedAttachments) : 0;
        for (CFIndex i = 0; i < count && i < CFArrayGetCount(attachments); ++i)
            CFDictionaryApplyFunction(CFArrayGetValueAtIndex(attachments, i), wk_vtdecode_copy_attachment, (void *)CFArrayGetValueAtIndex(copiedAttachments, i));
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

OSStatus VTDecompressionSessionDecodeFrame(WKVTDecompressionSessionRef decompressionSession, WKCMSampleBufferRef sampleBuffer,
    uint32_t decodeFlags, void *sourceFrameRefCon, uint32_t *infoFlagsOut)
{
    WKVTDecodeSession *session = wk_vtdecode_session(decompressionSession);
    WKCMFormatDescriptionRef format = session && sampleBuffer ? wk_system_CMSampleBufferGetFormatDescription()(sampleBuffer) : NULL;
    WKCMFormatDescriptionRef inRangeFormat = format ? wk_vtdecode_copy_in_range_format(session, format) : NULL;
    if (inRangeFormat && !wk_system_CMSampleBufferDataIsReady()(sampleBuffer)) {
        OSStatus readyStatus = wk_system_CMSampleBufferMakeDataReady()(sampleBuffer);
        if (readyStatus) {
            CFRelease(inRangeFormat);
            return readyStatus;
        }
    }
    WKCMSampleBufferRef inRangeSample = inRangeFormat ? wk_vtdecode_copy_sample(sampleBuffer, inRangeFormat) : NULL;
    if (inRangeFormat)
        CFRelease(inRangeFormat);
    if (inRangeFormat && !inRangeSample)
        return -12904; // kVTAllocationFailedErr

    OSStatus status = wk_system_VTDecompressionSessionDecodeFrame()(decompressionSession,
        inRangeSample ? inRangeSample : sampleBuffer, decodeFlags, sourceFrameRefCon, infoFlagsOut);
    if (inRangeSample)
        CFRelease(inRangeSample);
    return status;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(VTDecompressionSessionCreate, "VideoToolbox", &VTDecompressionSessionCreate, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(VTDecompressionSessionCanAcceptFormatDescription, "VideoToolbox", &VTDecompressionSessionCanAcceptFormatDescription, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(VTDecompressionSessionDecodeFrame, "VideoToolbox", &VTDecompressionSessionDecodeFrame, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
