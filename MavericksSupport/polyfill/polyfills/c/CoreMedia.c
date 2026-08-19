// CoreMedia: entry points and constants modern WebKit references that 10.9's CoreMedia does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>

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
    (void)tag;
    return 0;
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
