#pragma once

#include "PlatformExportMacros.h"
#import <QuartzCore/QuartzCore.h>

// Identifies WebKit's native background-filter surface; inherits CALayer behavior unchanged.
WEBCORE_EXPORT @interface WebBackdropLayerMavericks : CALayer
@end
