/*
 * CoreVideo colorimetry constants added in 10.11 / 10.13, absent on 10.9.
 *
 * Wide-gamut / HDR color tags. WebKit's bundled decoders reference them, and so do
 * GStreamer's applemedia plugins (vtdec/vtenc/avfvideosrc) and video plugins. Plain C so
 * the non-WebKit builds that carry no polyfill registry -- deps/build_deps.sh, which
 * force-loads these into every media dylib -- compile this same source. One definition of
 * each value, used by all of them.
 *
 * The values are CoreVideo's own on newer macOS. They only tag a frame's color space, so
 * defining them makes the references link and keeps a NULL key or value out of a
 * CoreVideo attachment dictionary; 10.9 does not act on the tags.
 *
 * WK_POLYFILL_REGISTERED is defined only by polyfill/scripts/build-polyfill.sh, i.e. only
 * when this file is built into libpolyfill.a for WebKit. It adds the registry entries and
 * nothing else.
 */

#include <CoreFoundation/CoreFoundation.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#define CV_CONST(NAME, VALUE) \
    const CFStringRef NAME = CFSTR(VALUE); \
    WK_PF_ENTRY(NAME, "CoreVideo", &NAME, WK_POLYFILL_CONSTANT, WK_POLYFILL_GAP_FILL)
#else
#define CV_CONST(NAME, VALUE) const CFStringRef NAME = CFSTR(VALUE)
#endif

CV_CONST(kCVImageBufferColorPrimaries_DCI_P3,             "DCI_P3");
CV_CONST(kCVImageBufferColorPrimaries_ITU_R_2020,         "ITU_R_2020");
CV_CONST(kCVImageBufferColorPrimaries_P3_D65,             "P3_D65");
CV_CONST(kCVImageBufferTransferFunction_ITU_R_2020,       "ITU_R_2020");
CV_CONST(kCVImageBufferTransferFunction_ITU_R_2100_HLG,   "ITU_R_2100_HLG");
CV_CONST(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, "SMPTE_ST_2084_PQ");
CV_CONST(kCVImageBufferTransferFunction_sRGB,             "IEC_sRGB");
CV_CONST(kCVImageBufferYCbCrMatrix_ITU_R_2020,            "ITU_R_2020");
