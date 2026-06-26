// MAVERICKS_BACKPORT: empty stub header. The real UIKitUtilities is iOS-only
// (UIKit) and lives in UIProcess/ios; this UIProcess placeholder satisfies
// `#import "UIKitUtilities.h"` from Cocoa sources so the Mac 10.9 build resolves
// the include without compiling the absent UIKit helpers.
#pragma once
