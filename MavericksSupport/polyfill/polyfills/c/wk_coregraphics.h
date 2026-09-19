#ifndef WK_COREGRAPHICS_H
#define WK_COREGRAPHICS_H

#include <CoreGraphics/CGContext.h>
#include <stdbool.h>
#include <stddef.h>

bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef);
size_t wk_coreAnimationTextureLimit(void);

#endif
