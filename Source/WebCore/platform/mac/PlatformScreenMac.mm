#include "config.h"
#include "PlatformScreen.h"
#include "ScreenProperties.h"
#include "DestinationColorSpace.h"
#include "FloatRect.h"
#include <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>

namespace WebCore {

PlatformDisplayID displayID(NSScreen *screen)
{
    return [[[screen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
}

ScreenProperties collectScreenProperties()
{
    ScreenProperties screenProperties;
    NSScreen *mainScreen = [NSScreen mainScreen];
    if (!mainScreen)
        return screenProperties;

    auto screenID = displayID(mainScreen);
    ScreenData screenData {
        FloatRect { mainScreen.visibleFrame },
        FloatRect { mainScreen.frame },
        DestinationColorSpace { adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB)) },
    };
    screenData.screenDepth = NSBitsPerPixelFromDepth(mainScreen.depth);
    screenData.screenDepthPerComponent = NSBitsPerSampleFromDepth(mainScreen.depth);
#if PLATFORM(MAC)
    screenData.displayMask = CGDisplayIDToOpenGLDisplayMask(screenID);
#endif

    screenProperties.screenDataMap.set(screenID, std::move(screenData));
    screenProperties.primaryDisplayID = screenID;

    return screenProperties;
}

// 10.9 backport: WebGL's resolveGraphicsContextGLAttributes calls gpuIDForDisplay to pin the EGL
// display to a specific GPU's IOKit registry ID. The upstream impl queries CGL renderer registry
// IDs (kCGLRPRegistryIDLow/High, 10.13+), which don't exist here, and this cut-down PlatformScreenMac
// omitted the function entirely — so it was an undefined symbol that crashed WebContent (lazy-bind
// failure) the moment getContext('webgl') was called. This VM has a single (software) GL renderer,
// so report 0 = "no specific GPU"; ANGLE then skips device-ID pinning for the EGL display.
PlatformGPUID gpuIDForDisplay(PlatformDisplayID)
{
    return 0;
}

PlatformGPUID gpuIDForDisplayMask(uint32_t)
{
    return 0;
}

PlatformGPUID primaryGPUID()
{
    return 0;
}

} // namespace WebCore
