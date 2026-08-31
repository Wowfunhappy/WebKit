// MediaAccessibility: entry points modern WebKit calls that 10.9's MediaAccessibility does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------------------------------
// MediaAccessibility — genuinely-absent feature; caller tolerates NULL (case (b)).
// ---------------------------------------------------------------------------------------------------

// MAAudibleMediaPrefCopyPreferDescriptiveVideo was added after 10.9. The MediaAccessibility framework
// itself exists on 10.9, so WebKit's SOFT_LINK library check passes, but dlsym of this symbol returns
// NULL and the SOFT_LINK RELEASE_ASSERTs. 10.9 has no "prefer descriptive video" accessibility
// preference, so return NULL: CaptionUserPreferencesMediaAF::userPrefersTextDescriptions() then reads
// `preferDescriptiveVideo && CFBooleanGetValue(...)` as false and falls back to the base preference.
WK_POLYFILL_ABSENT("MediaAccessibility", CFBooleanRef, MAAudibleMediaPrefCopyPreferDescriptiveVideo, (void))
{
    return NULL;
}
