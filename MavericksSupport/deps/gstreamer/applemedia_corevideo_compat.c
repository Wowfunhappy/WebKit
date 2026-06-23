/*
 * MAVERICKS_BACKPORT: CoreVideo compatibility shim for libgstapplemedia.dylib.
 *
 * The macOS-26-built applemedia plugin references 8 wide-gamut / HDR colorimetry constants added to
 * CoreVideo after 10.9. This shim REEXPORTS the real CoreVideo (so the plugin's ~20 pre-10.9 CV symbols
 * still resolve) and DEFINES the 8 missing constants with their canonical string values. avfvideosrc
 * uses them only to tag captured frames' color space, so the values matter only for correctness, not
 * for the camera to function.
 *
 * Built by build-applemedia-compat.sh, which repoints the plugin's CoreVideo load command to
 * @rpath/libcorevideo_compat.dylib (a high -compatibility_version so dyld accepts the substitution).
 */
#include <CoreFoundation/CoreFoundation.h>

#define D(n, v) const CFStringRef n = CFSTR(v);
D(kCVImageBufferColorPrimaries_DCI_P3, "DCI_P3")
D(kCVImageBufferColorPrimaries_ITU_R_2020, "ITU_R_2020")
D(kCVImageBufferColorPrimaries_P3_D65, "P3_D65")
D(kCVImageBufferTransferFunction_ITU_R_2020, "ITU_R_2020")
D(kCVImageBufferTransferFunction_ITU_R_2100_HLG, "ITU_R_2100_HLG")
D(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, "SMPTE_ST_2084_PQ")
D(kCVImageBufferTransferFunction_sRGB, "IEC_sRGB")
D(kCVImageBufferYCbCrMatrix_ITU_R_2020, "ITU_R_2020")
