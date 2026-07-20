/* A second image carrying the same polyfill as the test binary.
 *
 * Every shipped framework force-loads the polyfill archive, so a process really does contain several
 * copies of each polyfill. This dylib reproduces that, so the test can check that a copy in one image
 * is never mistaken for "10.9 has this symbol" by another. Getting that wrong makes two images defer
 * to each other instead of running the polyfill.
 */
#include "wk_polyfill.h"

#include <CoreGraphics/CoreGraphics.h>

WK_SYSTEM_FN("CoreGraphics", CFStringRef, CGColorSpaceCopyName, (CGColorSpaceRef));

WK_POLYFILL_ABSENT("CoreGraphics", CFStringRef, CGColorSpaceGetName, (CGColorSpaceRef space), (space))
{
    if (!WK_SYSTEM(CGColorSpaceCopyName))
        return NULL;
    CFStringRef name = WK_SYSTEM(CGColorSpaceCopyName)(space);
    return name ? (CFStringRef)CFAutorelease(name) : NULL;
}

/* Does this image think 10.9 has the symbol? It must not, no matter who else defines it. */
int wk_sibling_thinks_symbol_is_present(void)
{
    return WK_ORIGINAL(CGColorSpaceGetName) != NULL;
}
