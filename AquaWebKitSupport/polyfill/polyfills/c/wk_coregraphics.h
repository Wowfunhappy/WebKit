#ifndef WK_COREGRAPHICS_H
#define WK_COREGRAPHICS_H

#include <CoreGraphics/CGContext.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef);
size_t wk_coreAnimationTextureLimit(void);
void wk_beginBlendingGroupLayer(CGContextRef);
// The bitmap a cell's focus ring mask also draws into, under the context's CTM and clip, while the context has a
// transparency layer open under a focus ring QuartzCore's software renderer drops; NULL when none is.
// wk_endFocusRingMask ends the mask.
CGContextRef wk_beginFocusRingMask(CGContextRef);
void wk_endFocusRingMask(CGContextRef);

// A draw between these under a blend mode QuartzCore does not implement composites through a read-back of its
// surface. Begin answers whether it is taking place; the caller then draws into `target`.
typedef struct {
    CGContextRef context;
    CGContextRef target;
    CGBlendMode mode;
    CGRect region;
    uint8_t *destination;
    const void *style;
    bool blends;
    CGPoint textPosition;
    CGTextDrawingMode textMode;
    bool hsl;
    const void *shadow;
    CGContextRef masks;
    int maskReach;
} wk_blend_read_back;
bool wk_blendReadBackBegin(CGContextRef, wk_blend_read_back *);
void wk_blendReadBackEnd(wk_blend_read_back *);

// After a text draw ended: answers whether its clipping text mode has yet to reach the context, in which case the caller
// repeats the draw on the context and calls End.
bool wk_blendReadBackTextClipBegin(wk_blend_read_back *);
void wk_blendReadBackTextClipEnd(wk_blend_read_back *);

#endif
