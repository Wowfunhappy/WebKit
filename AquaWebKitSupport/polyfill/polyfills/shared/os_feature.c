/*
 * os_feature_enabled(domain, feature), libSystem's feature-flag query (10.13+), which reads the
 * domain's plist under /System/Library/FeatureFlags; 10.9 has none. Every caller gates a feature
 * that postdates 10.9 (WebKit's VisualIntelligence, Translate and TextComposer post-editing and the
 * redesigned text cursor; Apple ICU's ICU/longDayPeriodNames), so the answer on this OS is "not
 * enabled".
 *
 * Plain C: Apple's ICU in the deps build calls it too.
 */

#include <stdbool.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

bool _os_feature_enabled_impl(const char *domain, const char *feature)
{
    (void)domain;
    (void)feature;
    return false;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(_os_feature_enabled_impl, NULL, &_os_feature_enabled_impl, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
