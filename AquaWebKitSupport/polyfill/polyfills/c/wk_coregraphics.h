#ifndef WK_COREGRAPHICS_H
#define WK_COREGRAPHICS_H

#include <CoreGraphics/CGContext.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef);
size_t wk_coreAnimationTextureLimit(void);

// A draw between these under a blend mode QuartzCore does not implement composites through a read-back of its
// surface. Begin answers whether it is taking place; the caller then draws with the context's blend mode normal.
typedef struct {
    CGContextRef context;
    CGBlendMode mode;
    CGRect region;
    uint8_t *destination;
    const void *style;
} wk_blend_read_back;
bool wk_blendReadBackBegin(CGContextRef, wk_blend_read_back *);
void wk_blendReadBackEnd(wk_blend_read_back *);

#endif
