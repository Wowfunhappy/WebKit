#pragma once

#include "PlatformExportMacros.h"
#import <QuartzCore/QuartzCore.h>

// Identifies WebKit's native background-filter surface. A hidden instance has no background filters; the assigned
// ones return when it is shown.
WEBCORE_EXPORT @interface WebBackdropLayerMavericks : CALayer
@end
