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

} // namespace WebCore
