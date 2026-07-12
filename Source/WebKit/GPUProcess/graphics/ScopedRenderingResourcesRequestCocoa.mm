// Stubbed for MAVERICKS_BACKPORT — Metal not available.
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "ScopedRenderingResourcesRequest.h"

#if PLATFORM(COCOA)

#import <Metal/Metal.h>
#import <objc/NSObjCRuntime.h>
#import <pal/spi/cocoa/MetalSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>
#import <wtf/Seconds.h>

OBJC_PROTOCOL(MTLDevice);
OBJC_PROTOCOL(MTLDeviceSPI);

namespace WebKit {

static constexpr Seconds freeRenderingResourcesTimeout = 1_s;
static bool didScheduleFreeRenderingResources;

void ScopedRenderingResourcesRequest::scheduleFreeRenderingResources()
{
    if (didScheduleFreeRenderingResources)
        return;
    RunLoop::mainSingleton().dispatchAfter(freeRenderingResourcesTimeout, freeRenderingResources);
    didScheduleFreeRenderingResources = true;
}

void ScopedRenderingResourcesRequest::freeRenderingResources()
{
    didScheduleFreeRenderingResources = false;
    if (s_requests)
        return;
    BEGIN_BLOCK_OBJC_EXCEPTIONS
#if PLATFORM(MAC)
    auto devices = adoptNS(MTLCopyAllDevices());
    for (id<MTLDevice> device : devices.get()) {
        if ([device respondsToSelector:@selector(_purgeDevice)])
            [(_MTLDevice *)device _purgeDevice];
    }
#else
    RetainPtr<MTLDevice> devicePtr = adoptNS(MTLCreateSystemDefaultDevice());
    if ([devicePtr.get() respondsToSelector:@selector(_purgeDevice)])
        [(_MTLDevice *)devicePtr.get() _purgeDevice];
#endif
    END_BLOCK_OBJC_EXCEPTIONS
}

}

#endif
MAVERICKS_BACKPORT */
