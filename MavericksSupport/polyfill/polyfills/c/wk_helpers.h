// Helpers shared between two framework files of the polyfill archive. Every function here has
// hidden visibility (the archive is built with -fvisibility=hidden) and one definition per image.

#ifndef WK_HELPERS_H
#define WK_HELPERS_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Transparency-layer bookkeeping: CoreGraphics.c's CGContext{Begin,End}TransparencyLayer replacements
// count the layers open on each context, and CoreText.c's CTFontDrawGlyphs replacement asks.
void wk_transparencyLayerBegan(CGContextRef context);
void wk_transparencyLayerEnded(CGContextRef context);
bool wk_isInsideTransparencyLayer(CGContextRef context);

#ifdef __cplusplus
}
#endif

#endif // WK_HELPERS_H
