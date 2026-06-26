#pragma once
// MAVERICKS_BACKPORT: empty stub header. ScreenTime.framework is unavailable on
// macOS 10.9, so the real ScreenTimeWebsiteDataSupport (UIProcess) declarations are
// not provided here. This stub exists so a bare #include "ScreenTimeWebsiteDataSupport.h"
// resolved through the backport's header-search paths to NetworkProcess/cocoa/ finds an
// empty definition instead of failing the 10.9 build.
// stubbed
