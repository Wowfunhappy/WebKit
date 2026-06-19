// CGColorSpace entry points modern WebKit calls that 10.9 (CoreGraphics) lacks. Built into
// libcg_polyfill.dylib (embedded in WebCore.framework by install-safari7.sh).
#include <CoreGraphics/CoreGraphics.h>

extern CGColorSpaceModel CGColorSpaceGetModel(CGColorSpaceRef);
extern size_t CGColorSpaceGetNumberOfComponents(CGColorSpaceRef);
// 10.x+; weak so the comparison below still links/runs on 10.9 if it's absent.
extern CFPropertyListRef CGColorSpaceCopyPropertyList(CGColorSpaceRef) __attribute__((weak_import));

// 10.9 has no API to recover a colour space's name, so this returns NULL; callers
// (CoreIPCCGColorSpace) detect NULL and encode by colour-space model instead.
CFStringRef CGColorSpaceGetName(CGColorSpaceRef space) {
    (void)space;
    return NULL;
}

// Structural equality: identity, then model, component count, and property lists (when that
// API is present). Matches the comparison CoreGraphics gained in 10.10.
bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef a, CGColorSpaceRef b) {
    if (a == b) return true;
    if (!a || !b) return false;
    if (CGColorSpaceGetModel(a) != CGColorSpaceGetModel(b)) return false;
    if (CGColorSpaceGetNumberOfComponents(a) != CGColorSpaceGetNumberOfComponents(b)) return false;
    if (CGColorSpaceCopyPropertyList) {
        CFPropertyListRef pa = CGColorSpaceCopyPropertyList(a);
        CFPropertyListRef pb = CGColorSpaceCopyPropertyList(b);
        bool eq = (pa && pb) && CFEqual(pa, pb);
        if (pa) CFRelease(pa);
        if (pb) CFRelease(pb);
        return eq;
    }
    return true;
}
