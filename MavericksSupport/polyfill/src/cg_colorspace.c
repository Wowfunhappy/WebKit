// CGColorSpace entry points modern WebKit calls that 10.9 (CoreGraphics) lacks. Built into
// libcg_polyfill.dylib (embedded in WebCore.framework by install-safari7.sh).
#include <CoreGraphics/CoreGraphics.h>


// CGColorSpaceGetName (10.12+) has no 10.9 symbol, but CGColorSpaceCopyName IS present on 10.9 and
// recovers the same name (verified on-host: sRGB -> "kCGColorSpaceSRGB"). Forward to it and
// autorelease to match CGColorSpaceGetName's +0 "get" ownership. (The prior "10.9 has no API to
// recover a colour space's name" premise was false — CoreIPCCGColorSpace's name branch works now.)
extern CFStringRef CGColorSpaceCopyName(CGColorSpaceRef);
CFStringRef CGColorSpaceGetName(CGColorSpaceRef space) {
    CFStringRef name = CGColorSpaceCopyName(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

