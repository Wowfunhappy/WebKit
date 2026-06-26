// MAVERICKS_BACKPORT: empty stub header. The real UIKitUtilities.h lives in UIProcess/ios/ and is
// gated on PLATFORM(IOS_FAMILY); the shared Cocoa file WKWebView.mm unconditionally imports
// "UIKitUtilities.h", so this no-op header satisfies that import on the macOS 10.9 build where the
// iOS header's directory is not on the include search path.
#pragma once
