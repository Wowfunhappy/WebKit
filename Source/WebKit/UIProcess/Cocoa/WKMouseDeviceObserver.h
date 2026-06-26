#pragma once

// MAVERICKS_BACKPORT: the real WKMouseDeviceObserver lives under UIProcess/ios and only builds with HAVE(MOUSE_DEVICE_OBSERVATION) (off on 10.9). This empty Cocoa stub lets the guarded #import "WKMouseDeviceObserver.h" in WebProcessPoolCocoa.mm / WebProcessProxyCocoa.mm resolve on the Mac build, where the class itself is never referenced.
