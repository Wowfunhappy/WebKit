// DataDetectors: the scale-taking highlight constructor on 10.9.
#include "wk_polyfill.h"

#include <CoreGraphics/CoreGraphics.h>

#define DATA_DETECTORS_PROVIDER \
    "/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors"

typedef struct __DDHighlight *DDHighlightRef;

WK_SYSTEM_FN(DATA_DETECTORS_PROVIDER, DDHighlightRef, DDHighlightCreateWithRectsInVisibleRectWithStyleAndDirection,
    (CFAllocatorRef, CGRect *, CFIndex, CGRect, unsigned long, Boolean, long, Boolean, Boolean));

// scale is the backing scale factor a highlight's shapes are aligned to until it is drawn; 0 means
// that of the main window's screen, and DDHighlightGetLayerWithContext realigns them to its context's
// scale. DataDetectors defines ...WithStyleAndDirection as this function with scale 0. 10.9's
// ...WithStyleAndDirection builds the same highlight with its shapes aligned to whole points, the one
// grid 10.9's highlight geometry has, at creation and when drawn.
WK_POLYFILL_ABSENT(DATA_DETECTORS_PROVIDER, DDHighlightRef, DDHighlightCreateWithRectsInVisibleRectWithStyleScaleAndDirection,
    (CFAllocatorRef allocator, CGRect *rects, CFIndex count, CGRect globalVisibleRect, unsigned long style,
        Boolean withButton, long writingDirection, Boolean endsWithEOL, Boolean flipped, CGFloat scale))
{
    (void)scale;
    return WK_SYSTEM(DDHighlightCreateWithRectsInVisibleRectWithStyleAndDirection)(allocator, rects, count,
        globalVisibleRect, style, withButton, writingDirection, endsWithEOL, flipped);
}
