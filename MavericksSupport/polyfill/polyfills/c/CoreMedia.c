// CoreMedia: entry points and constants modern WebKit references that 10.9's CoreMedia does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The SDK spells these CoreMedia names as macros for their CoreVideo twins (which 10.9 exports).
// WebKit soft-links them by their CoreMedia NAME (SOFT_LINK_CONSTANT stringizes the unexpanded
// token and dlsym's it), so the definitions below must carry the CoreMedia symbol names.
#undef kCMFormatDescriptionExtension_ColorPrimaries
#undef kCMFormatDescriptionExtension_TransferFunction
#undef kCMFormatDescriptionExtension_YCbCrMatrix
#undef kCMFormatDescriptionExtension_PixelAspectRatio
#undef kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing
#undef kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing
#undef kCMFormatDescriptionColorPrimaries_ITU_R_709_2
#undef kCMFormatDescriptionColorPrimaries_EBU_3213
#undef kCMFormatDescriptionColorPrimaries_SMPTE_C
#undef kCMFormatDescriptionTransferFunction_ITU_R_709_2
#undef kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995

// ---------------------------------------------------------------------------------------------
// CoreMedia format-description constants (below).
//
// 10.9's CoreMedia exports exactly ONE of the colour-description constants modern WebKit uses
// (kCMFormatDescriptionColorPrimaries_P22); the other 60 CFStringRefs PAL soft-links are absent —
// runtime-verified by dlopen'ing CoreMedia and dlsym'ing all 111 names PAL declares, which is
// precisely what SOFT_LINK_CONSTANT does. That macro is unconditional: it RELEASE_ASSERTs the
// moment a missing constant is first read, so e.g. Google Meet killed the WebContent process
// within seconds of enabling the camera (canvas.captureStream -> WebGL surfaceBufferToVideoFrame
// -> VideoFrameCV::create -> computeVideoFrameColorSpace -> ...ColorPrimaries_DCI_P3). Defining
// them here makes the soft-link resolve instead of trapping.
//
// Two value regimes, same rule as the CoreText/ImageIO keys in their own files — a value the SYSTEM interprets
// must be the real one; a value only round-tripped through our own code may be a unique token.
//
// (1) REAL values. Every constant in this group is a documented synonym of a CoreVideo constant
// that 10.9 DOES export, and the value was read off this host rather than assumed
// (kCVImageBufferColorPrimaries_ITU_R_709_2 == "ITU_R_709_2", ...PixelAspectRatioKey ==
// "CVPixelAspectRatio", and so on). They are load-bearing in both directions: WebCore compares
// them against attachments 10.9's CoreVideo/VideoToolbox put on pixel buffers, and
// setVideoFrameColorSpace() writes them back as attachment values that 10.9 then interprets.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_ColorPrimaries, CFSTR("CVImageBufferColorPrimaries"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_TransferFunction, CFSTR("CVImageBufferTransferFunction"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_YCbCrMatrix, CFSTR("CVImageBufferYCbCrMatrix"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_PixelAspectRatio, CFSTR("CVPixelAspectRatio"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, CFSTR("HorizontalSpacing"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, CFSTR("VerticalSpacing"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_ITU_R_709_2, CFSTR("ITU_R_709_2"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_EBU_3213, CFSTR("EBU_3213"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_SMPTE_C, CFSTR("SMPTE_C"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_709_2, CFSTR("ITU_R_709_2"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995, CFSTR("SMPTE_240M_1995"));

// (2) Colour identifiers whose CoreVideo twins are ALSO absent on 10.9 (wide gamut, HDR, and the
// bit-depth key). Nothing on this OS emits or understands them, so the value cannot round-trip
// through the system either way — but they follow the identical, fully regular naming the group
// above was verified against (the identifier is the name's suffix: "ITU_R_709_2", "SMPTE_C",
// "P22", "SMPTE_240M_1995", "UseGamma" ...), so the real values are used rather than tokens. That
// keeps the classification in computeVideoFrameColorSpace() correct if a frame ever does arrive
// tagged by non-system code, and costs nothing if none does.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_DCI_P3, CFSTR("DCI_P3"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_P3_D65, CFSTR("P3_D65"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, CFSTR("SMPTE_ST_2084_PQ"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, CFSTR("ITU_R_2100_HLG"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_Linear, CFSTR("Linear"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1, CFSTR("SMPTE_ST_428_1"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_BitsPerComponent, CFSTR("BitsPerComponent"));

// (3) The two sample-attachment keys that are genuinely LIVE on this build. WebCore WRITES both
// into a CMSampleBuffer's attachments dictionary that it then hands to the system
// (CMUtilities.mm:561 and :598), so a name-string token would be a fabricated value inside a
// system-interpreted structure -- these need the real ones. The kCMSampleAttachmentKey_* naming
// rule was verified on this host across eight siblings that 10.9 DOES export (NotSync ==
// "NotSync", DoNotDisplay == "DoNotDisplay", IsDependedOnByOthers == "IsDependedOnByOthers",
// DependsOnOthers, HasRedundantCoding, DisplayImmediately, and the CMSampleBufferAttachmentKey_
// pair TrimDurationAtStart / EmptyMedia): the value is the name's suffix, verbatim.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMSampleAttachmentKey_HDR10PlusPerFrameData, CFSTR("HDR10PlusPerFrameData"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMSampleAttachmentKey_CryptorSubsampleAuxiliaryData, CFSTR("CryptorSubsampleAuxiliaryData"));

// NOT defined here, deliberately: the stereoscopic / immersive-video / per-lens camera-calibration
// keys. Every reference to them in FormatDescriptionUtilities.cpp sits inside
// #if HAVE(IMMERSIVE_VIDEO_METADATA_SUPPORT), which requires a 16.0 deployment target and is OFF on
// this 10.9 build (verified by walking the guard regions), so they can never be dlsym'd -- exactly
// the reasoning that keeps the four absent kCMTag* constants out too. Defining them with invented
// values would be worse than omitting them: FormatDescriptionUtilities.cpp bare-references those
// names, so enabling the flag would silently bind live code to fake keys with no diagnostic.

// ---------------------------------------------------------------------------------------------
// CoreMedia tagged buffer groups / CMTag (macOS 14+).
//
// This is the stereoscopic-video vocabulary: a "tagged buffer group" carries several pixel buffers
// for one sample (a left-eye and a right-eye image, say), and CMTags label which is which. 10.9 has
// none of it, and nothing on this OS can produce it -- a sample's media type is never
// kCMMediaType_TaggedBufferGroup, which is the runtime test every one of these calls sits behind in
// VideoMediaSampleRenderer::imageForSample(). So the honest implementation is the empty group: no
// buffers, no tags, nothing contained. That is also exactly what upstream's own code does with a
// monoscopic sample, so it takes the plain CMSampleBufferGetImageBuffer path unchanged.
//
// The CMTag types are themselves macOS 14+, so naming them in these prototypes is exactly the
// "unguarded" use the availability warning describes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

WK_POLYFILL_ABSENT("CoreMedia", CMTaggedBufferGroupRef, CMSampleBufferGetTaggedBufferGroup,
    (CMSampleBufferRef sampleBuffer))
{
    (void)sampleBuffer;
    return NULL;
}

WK_POLYFILL_ABSENT("CoreMedia", CMItemCount, CMTaggedBufferGroupGetCount, (CMTaggedBufferGroupRef group))
{
    (void)group;
    return 0;
}

WK_POLYFILL_ABSENT("CoreMedia", CMTagCollectionRef, CMTaggedBufferGroupGetTagCollectionAtIndex,
    (CMTaggedBufferGroupRef group, CFIndex index))
{
    (void)group; (void)index;
    return NULL;   // consistent with a count of 0: there is no index to be at
}

WK_POLYFILL_ABSENT("CoreMedia", CVPixelBufferRef, CMTaggedBufferGroupGetCVPixelBufferAtIndex,
    (CMTaggedBufferGroupRef group, CFIndex index))
{
    (void)group; (void)index;
    return NULL;
}

WK_POLYFILL_ABSENT("CoreMedia", Boolean, CMTagCollectionContainsTag,
    (CMTagCollectionRef tagCollection, CMTag tag))
{
    (void)tagCollection; (void)tag;
    return false;   // an empty collection contains nothing
}

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMTagCollectionGetTagsWithCategory,
    (CMTagCollectionRef tagCollection, CMTagCategory category, CMTag *tagBuffer,
     CMItemCount tagBufferCount, CMItemCount *numberOfTagsCopied))
{
    (void)tagCollection; (void)category; (void)tagBuffer; (void)tagBufferCount;
    // Succeeding with nothing copied is how the real routine reports "no tags of that category",
    // and it is what the caller checks: upstream requires numberOfTagsCopied == 1 to use the tag.
    if (numberOfTagsCopied)
        *numberOfTagsCopied = 0;
    return noErr;
}

WK_POLYFILL_ABSENT("CoreMedia", int64_t, CMTagGetSInt64Value, (CMTag tag))
{
    return (int64_t)tag.value;
}

// The tag constants, composed exactly as CMTag.h documents them: kCMTagInvalid is the sentinel whose
// dataType is kCMTagDataType_Invalid (what CMTAG_IS_VALID tests), and the two stereo tags are
// category kCMTagCategory_StereoView carrying the matching kCMStereoView_* flag. So these are the
// real values, not placeholders -- though nothing on 10.9 can produce a tag to compare them against.
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagInvalid,
                  ((CMTag){ kCMTagCategory_Undefined, kCMTagDataType_Invalid, 0 }));
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagStereoLeftEye,
                  ((CMTag){ kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_LeftEye }));
WK_POLYFILL_CONST("CoreMedia", CMTag, kCMTagStereoRightEye,
                  ((CMTag){ kCMTagCategory_StereoView, kCMTagDataType_Flags, kCMStereoView_RightEye }));

// The hero-eye format-description extension: which eye to show when a stereo pair is presented
// monoscopically. 10.9 writes no format-description extensions of this kind and reads none, so this
// key is only ever looked up in dictionaries that cannot contain it -- CMFormatDescriptionGetExtension
// returns NULL and upstream falls through to its LayerID=0 path. The spellings match the constants'
// names, so a log or a debugger shows something meaningful.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_HeroEye, CFSTR("HeroEye"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionHeroEye_Left, CFSTR("LeftEye"));
#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------
// CoreMedia
//
// Both of these are 10.10 conveniences over a 10.9 entry point that is still there and still does
// the work; each is defined in terms of the one it wraps, so the behaviour is the OS's own.

// Both bodies reach 10.9's CoreMedia through WK_SYSTEM_FN rather than by calling it directly: a
// direct call emits an undefined symbol that EVERY image force-loading this archive has to satisfy,
// including JavaScriptCore and the NetworkProcess, which have no reason to link CoreMedia. (Observed:
// a direct call here failed the JavaScriptCore link on CMSampleBufferCreate and
// CMSampleBufferCallForEachSample.) See the WK_SYSTEM_FN note in mechanism/wk_polyfill.h.
WK_SYSTEM_FN("CoreMedia", OSStatus, CMSampleBufferCreate,
    (CFAllocatorRef, CMBlockBufferRef, Boolean, CMSampleBufferMakeDataReadyCallback, void *,
     CMFormatDescriptionRef, CMItemCount, CMItemCount, const CMSampleTimingInfo *, CMItemCount,
     const size_t *, CMSampleBufferRef *));

WK_SYSTEM_FN("CoreMedia", OSStatus, CMSampleBufferCallForEachSample,
    (CMSampleBufferRef, OSStatus (*)(CMSampleBufferRef, CMItemCount, void *), void *));

// CMSampleBufferCreateReady is CMSampleBufferCreate with dataReady=true and no make-data-ready
// callback -- that is its definition, not an approximation of it. The two argument lists are
// identical apart from those three parameters.
WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMSampleBufferCreateReady,
    (CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, CMFormatDescriptionRef formatDescription,
     CMItemCount numSamples, CMItemCount numSampleTimingEntries,
     const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries,
     const size_t *sampleSizeArray, CMSampleBufferRef *sampleBufferOut))
{
    if (!WK_SYSTEM(CMSampleBufferCreate))
        return kCMSampleBufferError_AllocationFailed;
    return WK_SYSTEM(CMSampleBufferCreate)(allocator, dataBuffer, true, NULL, NULL, formatDescription,
                                           numSamples, numSampleTimingEntries, sampleTimingArray,
                                           numSampleSizeEntries, sampleSizeArray, sampleBufferOut);
}

// CMSampleBufferCallBlockForEachSample is the block-taking form of CMSampleBufferCallForEachSample,
// which 10.9 has. The function-pointer form already carries a refcon, so the block travels in it and
// this trampoline hands each sample to it; the handler's OSStatus is returned unchanged, so an
// early-out (a non-zero status) stops the iteration exactly as it does on the block form.
static OSStatus wkCallBlockForEachSampleTrampoline(CMSampleBufferRef sampleBuffer, CMItemCount index,
                                                   void *refcon)
{
    OSStatus (^handler)(CMSampleBufferRef, CMItemCount) = (OSStatus (^)(CMSampleBufferRef, CMItemCount))refcon;
    return handler(sampleBuffer, index);
}

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMSampleBufferCallBlockForEachSample,
    (CMSampleBufferRef sampleBuffer, OSStatus (^handler)(CMSampleBufferRef, CMItemCount)))
{
    if (!handler)
        return kCMSampleBufferError_RequiredParameterMissing;
    if (!WK_SYSTEM(CMSampleBufferCallForEachSample))
        return kCMSampleBufferError_AllocationFailed;
    return WK_SYSTEM(CMSampleBufferCallForEachSample)(sampleBuffer, wkCallBlockForEachSampleTrampoline,
                                                      (void *)handler);
}

// libpolyfill.a is force-loaded into images that have no reason to link CoreMedia (the XPC service
// executables, JavaScriptCore), so the CoreMedia entry point and key this file reads are resolved by
// name at first use rather than linked. The atom names are the ISO/IEC 14496-15 four-character
// codes, which are part of the format, not of CoreMedia.
WK_SYSTEM_FN("CoreMedia", CFPropertyListRef, CMFormatDescriptionGetExtension,
    (CMFormatDescriptionRef, CFStringRef));
WK_SYSTEM_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);

static CFDataRef wkSampleDescriptionAtom(CMFormatDescriptionRef description, CFStringRef atomName)
{
    CFStringRef atomsKey = WK_SYSTEM(kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!WK_SYSTEM(CMFormatDescriptionGetExtension) || !atomsKey)
        return NULL;
    CFDictionaryRef atoms = (CFDictionaryRef)WK_SYSTEM(CMFormatDescriptionGetExtension)(description,
        atomsKey);
    if (!atoms || CFGetTypeID(atoms) != CFDictionaryGetTypeID())
        return NULL;
    CFTypeRef atom = CFDictionaryGetValue(atoms, atomName);
    // A sample description carries the atom either as the data itself or as a one-element array of
    // it; 10.9's CMVideoFormatDescriptionGetH264ParameterSetAtIndex reads both spellings.
    if (atom && CFGetTypeID(atom) == CFArrayGetTypeID()) {
        if (!CFArrayGetCount((CFArrayRef)atom))
            return NULL;
        atom = CFArrayGetValueAtIndex((CFArrayRef)atom, 0);
    }
    if (!atom || CFGetTypeID(atom) != CFDataGetTypeID())
        return NULL;
    return (CFDataRef)atom;
}

// ISO/IEC 14496-15 HEVCDecoderConfigurationRecord: a 22-byte header whose last byte carries
// lengthSizeMinusOne, then numOfArrays arrays, each a NAL-unit-type byte, a 16-bit NALU count and
// that many 16-bit-length-prefixed payloads. Bytes 1..12 are the general profile_tier_level, which
// an HEVC SPS carries verbatim at the same width right after its first RBSP byte.
enum { wkHVCCHeaderSize = 23, wkHVCCArrayCountOffset = 22 };

// H.265 emulation prevention: a 0x03 following two zero bytes is not part of the RBSP.
static size_t wkRemoveEmulationPreventionBytes(const uint8_t *nalu, size_t size, uint8_t *rbsp)
{
    size_t out = 0, zeros = 0;
    for (size_t i = 0; i < size; ++i) {
        if (zeros >= 2 && nalu[i] == 0x03) {
            zeros = 0;
            continue;
        }
        zeros = nalu[i] ? 0 : zeros + 1;
        rbsp[out++] = nalu[i];
    }
    return out;
}

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t bit;
    bool overrun;
} wkBitReader;

static uint32_t wkReadBits(wkBitReader *reader, unsigned count)
{
    uint32_t value = 0;
    for (unsigned i = 0; i < count; ++i) {
        size_t index = reader->bit >> 3;
        if (index >= reader->size) {
            reader->overrun = true;
            return value;
        }
        value = (value << 1) | ((reader->data[index] >> (7 - (reader->bit & 7))) & 1);
        ++reader->bit;
    }
    return value;
}

// ue(v): the Exp-Golomb code H.265 uses for most syntax elements.
static uint32_t wkReadExpGolomb(wkBitReader *reader)
{
    unsigned leadingZeros = 0;
    while (!wkReadBits(reader, 1)) {
        if (reader->overrun || ++leadingZeros > 31)
            return 0;
    }
    if (!leadingZeros)
        return 0;
    return (1u << leadingZeros) - 1 + wkReadBits(reader, leadingZeros);
}

// profile_tier_level(1, maxNumSubLayersMinus1), H.265 7.3.3: the 12 general bytes this record shares
// with the SPS, then the sub-layer present flags and one 11-byte block per sub-layer that has them.
static void wkSkipProfileTierLevel(wkBitReader *reader, unsigned maxNumSubLayersMinus1)
{
    reader->bit += 96;
    bool profilePresent[8] = { false }, levelPresent[8] = { false };
    for (unsigned i = 0; i < maxNumSubLayersMinus1; ++i) {
        profilePresent[i] = wkReadBits(reader, 1);
        levelPresent[i] = wkReadBits(reader, 1);
    }
    if (maxNumSubLayersMinus1)
        reader->bit += 2 * (8 - maxNumSubLayersMinus1);
    for (unsigned i = 0; i < maxNumSubLayersMinus1; ++i) {
        if (profilePresent[i])
            reader->bit += 88;
        if (levelPresent[i])
            reader->bit += 8;
    }
}

// The picture dimensions and the general profile_tier_level bytes an HEVCDecoderConfigurationRecord
// needs, read out of the SPS that carries them (H.265 7.3.2.2). NAL header is 2 bytes.
typedef struct {
    int32_t width;
    int32_t height;
    uint8_t profileTierLevel[12];       // the general bytes hvcC shares with the SPS
    unsigned chromaFormatIdc;
    unsigned bitDepthLumaMinus8;
    unsigned bitDepthChromaMinus8;
    unsigned numTemporalLayers;
    unsigned temporalIdNested;
} wkHEVCSequenceParameters;

static bool wkParseHEVCSPS(const uint8_t *nalu, size_t size, wkHEVCSequenceParameters *out,
                           uint8_t *rbspBuffer)
{
    if (size < 4)
        return false;
    size_t rbspSize = wkRemoveEmulationPreventionBytes(nalu + 2, size - 2, rbspBuffer);
    if (rbspSize < 14)
        return false;

    wkBitReader reader = { rbspBuffer, rbspSize, 0, false };
    wkReadBits(&reader, 4);                                     // sps_video_parameter_set_id
    unsigned maxSubLayersMinus1 = wkReadBits(&reader, 3);
    out->temporalIdNested = wkReadBits(&reader, 1);
    out->numTemporalLayers = maxSubLayersMinus1 + 1;
    memcpy(out->profileTierLevel, rbspBuffer + 1, sizeof(out->profileTierLevel));
    wkSkipProfileTierLevel(&reader, maxSubLayersMinus1);
    wkReadExpGolomb(&reader);                                   // sps_seq_parameter_set_id
    out->chromaFormatIdc = wkReadExpGolomb(&reader);
    if (out->chromaFormatIdc == 3)
        wkReadBits(&reader, 1);                                 // separate_colour_plane_flag
    uint32_t width = wkReadExpGolomb(&reader);
    uint32_t height = wkReadExpGolomb(&reader);
    if (wkReadBits(&reader, 1)) {
        // conformance window, in chroma units (H.265 table 6-1): the picture is coded in whole
        // coding blocks and cropped down to the dimensions a description reports.
        uint32_t left = wkReadExpGolomb(&reader), right = wkReadExpGolomb(&reader);
        uint32_t top = wkReadExpGolomb(&reader), bottom = wkReadExpGolomb(&reader);
        uint32_t subWidth = (out->chromaFormatIdc == 1 || out->chromaFormatIdc == 2) ? 2 : 1;
        uint32_t subHeight = out->chromaFormatIdc == 1 ? 2 : 1;
        uint32_t cropX = subWidth * (left + right), cropY = subHeight * (top + bottom);
        if (cropX >= width || cropY >= height)
            return false;
        width -= cropX;
        height -= cropY;
    }
    out->bitDepthLumaMinus8 = wkReadExpGolomb(&reader);
    out->bitDepthChromaMinus8 = wkReadExpGolomb(&reader);
    if (reader.overrun || !width || !height || width > INT32_MAX || height > INT32_MAX)
        return false;
    out->width = (int32_t)width;
    out->height = (int32_t)height;
    return true;
}

static const uint8_t wkHEVCParameterSetTypes[] = { 32, 33, 34, 39, 40 };

static int wkHEVCParameterSetTypeIndex(uint8_t type)
{
    for (size_t i = 0; i < sizeof(wkHEVCParameterSetTypes); ++i) {
        if (wkHEVCParameterSetTypes[i] == type)
            return (int)i;
    }
    return -1;
}

// typeCounts is how many sets the caller counted of each wkHEVCParameterSetTypes entry, so every
// nal_unit_type here is already one this record can carry.
static CFDataRef wkCreateHEVCConfigurationRecord(CFAllocatorRef allocator, size_t parameterSetCount,
    const uint8_t *const *parameterSetPointers, const size_t *parameterSetSizes,
    int NALUnitHeaderLength, const uint16_t *typeCounts, wkHEVCSequenceParameters *sequenceOut)
{
    bool haveSequence = false;
    for (size_t i = 0; i < parameterSetCount && !haveSequence; ++i) {
        if (((parameterSetPointers[i][0] >> 1) & 0x3f) != 33)   // nal_unit_type SPS_NUT
            continue;
        uint8_t *rbsp = (uint8_t *)malloc(parameterSetSizes[i]);
        if (!rbsp)
            return NULL;
        haveSequence = wkParseHEVCSPS(parameterSetPointers[i], parameterSetSizes[i], sequenceOut, rbsp);
        free(rbsp);
    }
    if (!haveSequence)
        return NULL;

    uint8_t header[wkHVCCHeaderSize];
    memset(header, 0, sizeof(header));
    header[0] = 1;                                              // configurationVersion
    memcpy(header + 1, sequenceOut->profileTierLevel, 12);
    header[13] = 0xf0;                                          // min_spatial_segmentation_idc = 0
    header[15] = 0xfc;                                          // parallelismType = 0
    header[16] = (uint8_t)(0xfc | (sequenceOut->chromaFormatIdc & 0x03));
    header[17] = (uint8_t)(0xf8 | (sequenceOut->bitDepthLumaMinus8 & 0x07));
    header[18] = (uint8_t)(0xf8 | (sequenceOut->bitDepthChromaMinus8 & 0x07));
    header[21] = (uint8_t)(((sequenceOut->numTemporalLayers & 0x07) << 3)
        | ((sequenceOut->temporalIdNested & 0x01) << 2) | ((NALUnitHeaderLength - 1) & 0x03));

    for (size_t i = 0; i < sizeof(wkHEVCParameterSetTypes); ++i)
        header[wkHVCCArrayCountOffset] += !!typeCounts[i];

    CFMutableDataRef record = CFDataCreateMutable(allocator, 0);
    if (!record)
        return NULL;
    CFDataAppendBytes(record, header, sizeof(header));
    for (size_t typeIndex = 0; typeIndex < sizeof(wkHEVCParameterSetTypes); ++typeIndex) {
        if (!typeCounts[typeIndex])
            continue;
        uint8_t arrayHeader[] = {
            (uint8_t)(0x80 | wkHEVCParameterSetTypes[typeIndex]),
            (uint8_t)(typeCounts[typeIndex] >> 8),
            (uint8_t)typeCounts[typeIndex]
        };
        CFDataAppendBytes(record, arrayHeader, sizeof(arrayHeader));
        for (size_t i = 0; i < parameterSetCount; ++i) {
            if (((parameterSetPointers[i][0] >> 1) & 0x3f) != wkHEVCParameterSetTypes[typeIndex])
                continue;
            uint8_t size[] = {
                (uint8_t)(parameterSetSizes[i] >> 8),
                (uint8_t)parameterSetSizes[i]
            };
            CFDataAppendBytes(record, size, sizeof(size));
            CFDataAppendBytes(record, parameterSetPointers[i], (CFIndex)parameterSetSizes[i]);
        }
    }
    return record;
}

WK_SYSTEM_FN("CoreMedia", OSStatus, CMVideoFormatDescriptionCreate,
    (CFAllocatorRef, CMVideoCodecType, int32_t, int32_t, CFDictionaryRef, CMVideoFormatDescriptionRef *));

// The HEVC parameter-set entry points are 10.13 and 10.9's CoreMedia has neither. They are format
// description accessors: they build and parse the hvcC atom, the representation CoreMedia stores a
// sample description's HEVC configuration in. Whether anything can then decode such a description is
// VideoToolbox's answer to give through VTDecompressionSessionCreate.
WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMVideoFormatDescriptionCreateFromHEVCParameterSets,
    (CFAllocatorRef allocator, size_t parameterSetCount, const uint8_t *const *parameterSetPointers,
     const size_t *parameterSetSizes, int NALUnitHeaderLength, CFDictionaryRef extensions,
     CMFormatDescriptionRef *formatDescriptionOut))
{
    if (formatDescriptionOut)
        *formatDescriptionOut = NULL;
    if (!formatDescriptionOut || parameterSetCount < 3 || !parameterSetPointers || !parameterSetSizes
        || (NALUnitHeaderLength != 1 && NALUnitHeaderLength != 2 && NALUnitHeaderLength != 4))
        return kCMFormatDescriptionError_InvalidParameter;
    uint16_t typeCounts[sizeof(wkHEVCParameterSetTypes)] = { 0 };
    for (size_t i = 0; i < parameterSetCount; ++i) {
        if (!parameterSetPointers[i] || parameterSetSizes[i] < 2 || parameterSetSizes[i] > 0xffff)
            return kCMFormatDescriptionError_InvalidParameter;
        int typeIndex = wkHEVCParameterSetTypeIndex((parameterSetPointers[i][0] >> 1) & 0x3f);
        if (typeIndex < 0 || typeCounts[typeIndex] == UINT16_MAX)
            return kCMFormatDescriptionError_InvalidParameter;
        ++typeCounts[typeIndex];
    }
    if (!typeCounts[0] || !typeCounts[1] || !typeCounts[2])
        return kCMFormatDescriptionError_InvalidParameter;
    CFStringRef atomsKey = WK_SYSTEM(kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!WK_SYSTEM(CMVideoFormatDescriptionCreate) || !atomsKey)
        return kCMFormatDescriptionError_AllocationFailed;

    wkHEVCSequenceParameters sequence;
    CFDataRef record = wkCreateHEVCConfigurationRecord(allocator, parameterSetCount, parameterSetPointers,
        parameterSetSizes, NALUnitHeaderLength, typeCounts, &sequence);
    if (!record)
        return kCMFormatDescriptionError_InvalidParameter;

    OSStatus status = kCMFormatDescriptionError_AllocationFailed;
    CFDictionaryRef extensionAtoms = extensions ? CFDictionaryGetValue(extensions, atomsKey) : NULL;
    CFMutableDictionaryRef atoms = extensionAtoms && CFGetTypeID(extensionAtoms) == CFDictionaryGetTypeID()
        ? CFDictionaryCreateMutableCopy(allocator, 0, extensionAtoms)
        : CFDictionaryCreateMutable(allocator, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef merged = extensions
        ? CFDictionaryCreateMutableCopy(allocator, 0, extensions)
        : CFDictionaryCreateMutable(allocator, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (atoms && merged) {
        CFDictionarySetValue(atoms, CFSTR("hvcC"), record);
        CFDictionarySetValue(merged, atomsKey, atoms);
        status = WK_SYSTEM(CMVideoFormatDescriptionCreate)(allocator, kCMVideoCodecType_HEVC,
            sequence.width, sequence.height, merged, formatDescriptionOut);
    }
    if (atoms)
        CFRelease(atoms);
    if (merged)
        CFRelease(merged);
    CFRelease(record);
    return status;
}

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMVideoFormatDescriptionGetHEVCParameterSetAtIndex,
    (CMFormatDescriptionRef videoDesc, size_t parameterSetIndex, const uint8_t **parameterSetPointerOut,
     size_t *parameterSetSizeOut, size_t *parameterSetCountOut, int *NALUnitHeaderLengthOut))
{
    if (!videoDesc)
        return kCMFormatDescriptionError_InvalidParameter;
    CFDataRef hvcC = wkSampleDescriptionAtom(videoDesc, CFSTR("hvcC"));
    if (!hvcC)
        return kCMFormatDescriptionError_ValueNotAvailable;
    const uint8_t *record = CFDataGetBytePtr(hvcC);
    CFIndex length = CFDataGetLength(hvcC);
    if (!record || length < wkHVCCHeaderSize)
        return kCMFormatDescriptionError_ValueNotAvailable;

    size_t count = 0;
    size_t offset = wkHVCCHeaderSize;
    size_t setSize = 0;
    const uint8_t *set = NULL;
    unsigned arrayCount = record[wkHVCCArrayCountOffset];
    for (unsigned array = 0; array < arrayCount; ++array) {
        if (offset + 3 > (size_t)length)
            return kCMFormatDescriptionError_ValueNotAvailable;
        unsigned naluCount = ((unsigned)record[offset + 1] << 8) | record[offset + 2];
        offset += 3;
        for (unsigned nalu = 0; nalu < naluCount; ++nalu) {
            if (offset + 2 > (size_t)length)
                return kCMFormatDescriptionError_ValueNotAvailable;
            size_t size = ((size_t)record[offset] << 8) | record[offset + 1];
            offset += 2;
            if (offset + size > (size_t)length)
                return kCMFormatDescriptionError_ValueNotAvailable;
            if (count == parameterSetIndex) {
                set = record + offset;
                setSize = size;
            }
            offset += size;
            ++count;
        }
    }

    if (parameterSetPointerOut || parameterSetSizeOut) {
        if (!set)
            return kCMFormatDescriptionError_InvalidParameter;
        if (parameterSetPointerOut)
            *parameterSetPointerOut = set;
        if (parameterSetSizeOut)
            *parameterSetSizeOut = setSize;
    }
    if (parameterSetCountOut)
        *parameterSetCountOut = count;
    if (NALUnitHeaderLengthOut)
        *NALUnitHeaderLengthOut = (record[21] & 0x03) + 1;
    return noErr;
}

// CMSampleBufferCreateReadyWithImageBuffer (10.10+) is the dataReady = true form of the 10.7
// CMSampleBufferCreateForImageBuffer, beside CMSampleBufferCreateReady above; WebCore's MediaStream
// renderer builds every video sample buffer through it (createVideoSampleBuffer).
WK_SYSTEM_FN("CoreMedia", OSStatus, CMSampleBufferCreateForImageBuffer,
    (CFAllocatorRef, CVImageBufferRef, Boolean, CMSampleBufferMakeDataReadyCallback, void *,
     CMFormatDescriptionRef, const CMSampleTimingInfo *, CMSampleBufferRef *));

WK_POLYFILL_ABSENT("CoreMedia", OSStatus, CMSampleBufferCreateReadyWithImageBuffer,
    (CFAllocatorRef allocator, CVImageBufferRef imageBuffer, CMFormatDescriptionRef formatDescription,
     const CMSampleTimingInfo *sampleTiming, CMSampleBufferRef *sampleBufferOut))
{
    if (!WK_SYSTEM(CMSampleBufferCreateForImageBuffer))
        return kCMSampleBufferError_AllocationFailed;
    return WK_SYSTEM(CMSampleBufferCreateForImageBuffer)(allocator, imageBuffer, true, NULL, NULL,
                                                          formatDescription, sampleTiming, sampleBufferOut);
}
