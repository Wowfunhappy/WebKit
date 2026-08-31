// QuartzCore: entry points and constants modern WebKit references that 10.9's QuartzCore does not export.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

// WK_POLYFILL_CONST spells the type ahead of the name ("const TYPE NAME"), so a pointer constant
// needs a typedef for the const to land on the POINTER -- the "NSString * const" shape the SDK
// declares these with, rather than a pointer to const.
typedef NSString *PolyNSStringConst;

// CAFrameRateRangeMake (12.0+) -- CADisplayLink frame-rate range constructor. Build the
// {minimum,maximum,preferred} struct directly. (The struct type is itself 12.0+, so naming it in
// the prototype is exactly the "unguarded" use the availability warning describes.)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
WK_POLYFILL_ABSENT("QuartzCore", CAFrameRateRange, CAFrameRateRangeMake,
    (float minimum, float maximum, float preferred)) {
    CAFrameRateRange r = { minimum, maximum, preferred };
    return r;
}
#pragma clang diagnostic pop

// kCACornerCurveCircular (10.15+) has no 10.9 symbol. Define it with the documented value so the
// corner-curve path degrades gracefully and never feeds a NULL key to a CFDictionary (which would
// crash). 10.9 won't honor the value, which is fine.
WK_POLYFILL_CONST("QuartzCore", CALayerCornerCurve, kCACornerCurveCircular, @"circular");

// --- CoreAnimation CAFilter HSL (non-separable) blend-mode names (10.10+) -----------------
// 10.9's QuartzCore has the separable blend modes (multiply/overlay/screen/...) but not the four HSL
// ones (CSS mix-blend-mode: hue/saturation/color/luminosity). PlatformCAFiltersCocoa references all of
// them; define the missing four so it links. 10.9's CoreAnimation does not implement these filters, so
// CAFilter rejects the unknown name and the blend degrades to normal compositing — the separable modes
// (which 10.9 does support) are unaffected.
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterHueBlendMode, @"hueBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterSaturationBlendMode, @"saturationBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterColorBlendMode, @"colorBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterLuminosityBlendMode, @"luminosityBlendMode");
