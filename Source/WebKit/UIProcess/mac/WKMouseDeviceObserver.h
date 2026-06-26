// MAVERICKS_BACKPORT: Empty stub header provided for the 10.9 build. Base 83b24ce ships
// WKMouseDeviceObserver.mm/.swift and #import "WKMouseDeviceObserver.h" sites
// (WebProcessPoolCocoa.mm, WebProcessProxyCocoa.mm) plus a modulemap entry, but no matching
// header on this path; mouse-device observation is an iOS/newer-macOS facility we don't ship,
// so this header resolves those imports as a no-op.
#pragma once
