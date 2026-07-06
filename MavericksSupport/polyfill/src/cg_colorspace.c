// CGColorSpace entry points modern WebKit calls that 10.9 (CoreGraphics) lacks. Built into
// libcg_polyfill.dylib (embedded in WebCore.framework by install-safari7.sh).
#include <CoreGraphics/CoreGraphics.h>


// 10.9 has no API to recover a colour space's name, so this returns NULL; callers
// (CoreIPCCGColorSpace) detect NULL and encode by colour-space model instead.
CFStringRef CGColorSpaceGetName(CGColorSpaceRef space) {
    (void)space;
    return NULL;
}

