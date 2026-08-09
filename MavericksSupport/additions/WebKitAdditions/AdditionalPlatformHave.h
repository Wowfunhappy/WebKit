// MAVERICKS_BACKPORT: the port's HAVE_* values, supplied through the hook PlatformHave.h already has
// for exactly this ("additions to PlatformHave.h from outside the main repository"). Every block it
// preempts is `#if !defined(HAVE_X)`-guarded upstream, so defining the value here keeps
// Source/WTF/wtf/PlatformHave.h byte-upstream. The directory holding this file goes on the include
// path from Source/cmake/OptionsMac.cmake.

#pragma once

// AppKit runs pending -layout passes as part of every window's display cycle from 10.10 on, which is
// what makes -setNeedsLayout:YES guarantee -layout before the next draw. 10.9 runs that pass only for
// a window whose autolayout engine is engaged (measured on 10.9.5: needsLayout + display runs -layout
// with a constraint present and never without one), so a view that lays its subviews out only in
// -layout stays at its initial frames. Views that rely on the implicit pass run it from -viewWillDraw
// when this is off. Not an upstream macro — this port introduces it.
#define HAVE_NSVIEW_IMPLICIT_LAYOUT_PASS 0

// VisionKit image analysis (VKCImageAnalysis) on Mac is macOS 13+.
#define HAVE_VK_IMAGE_ANALYSIS 0

// The modern AuthenticationServices credential manager needs macOS 14; with it on, the isUVPAA path in
// WebAuthenticatorCoordinatorProxy names a soft-link getter whose header only comes in under
// HAVE(WEB_AUTHN_AS_MODERN), which is off at this deployment target. Off, the forward declaration, the
// soft link and the use compile out together. Unreachable here regardless: isUVPAA answers false
// earlier through the nil ASCWebKitSPISupport class.
#define HAVE_WEB_AUTHN_PUBLIC_KEY_CREDENTIAL_MANAGER 0

// This one describes the SDK, not the deployment target: it decides whether WebKit's SPI headers
// re-declare types (IOSurfaceMemoryLedgerTags and friends) that a newer SDK already declares. The
// build SDK is macOS 26.1, so they are declared.
#define HAVE_BROWSER_ENGINE_SUPPORTING_API 1
