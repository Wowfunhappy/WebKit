// Helpers shared between two framework files of the polyfill archive. Every function here has
// hidden visibility (the archive is built with -fvisibility=hidden) and one definition per image.

#ifndef WK_HELPERS_H
#define WK_HELPERS_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// CGContextGetType's PDF result, measured on 10.9; bitmap contexts report 4. Matches
// kCGContextTypePDF in PAL's CoreGraphicsSPI.h.
#define WK_CG_CONTEXT_TYPE_PDF 1

// Transparency-layer bookkeeping: CoreGraphics.c's CGContext{Begin,End}TransparencyLayer replacements
// count the layers open on each PDF context, and CoreText.c's CTFontDrawGlyphs replacement asks.
// Only PDF contexts are tracked — the one consumer converts glyphs to outlines only there, and
// leaving screen contexts untracked keeps the lock and the allocation off every painted layer.
void wk_transparencyLayerBegan(CGContextRef context);
void wk_transparencyLayerEnded(CGContextRef context);
bool wk_isInsideTransparencyLayer(CGContextRef context);

#ifdef __cplusplus
}
#endif

#endif // WK_HELPERS_H
