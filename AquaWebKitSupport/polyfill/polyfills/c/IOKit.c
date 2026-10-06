// IOKit: entry points and constants modern WebKit references that 10.9's IOKit does not export.
#include "wk_polyfill.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>

// kIOMainPortDefault (12.0) is the current name of kIOMasterPortDefault, which 10.9 does ship. Both
// are the same value — MACH_PORT_NULL, the "use the default master port" sentinel IOKit resolves
// internally — so the rename is the whole of the difference.
WK_POLYFILL_CONST("IOKit", mach_port_t, kIOMainPortDefault, 0);

// IOMainPort (the macOS 12.0 rename of IOMasterPort) has no 10.9 runtime symbol; forward to
// IOMasterPort, which 10.9 ships. Both are declared in the 26.1 SDK's IOKitLib.h, so WebCore can call
// the upstream IOMainPort name unchanged (platform/graphics/mac/GraphicsChecksMac.cpp).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
WK_SYSTEM_FN("IOKit", kern_return_t, IOMasterPort, (mach_port_t, mach_port_t *));
WK_POLYFILL_ABSENT("IOKit", kern_return_t, IOMainPort, (mach_port_t bootstrapPort, mach_port_t *mainPort))
{
    if (!WK_SYSTEM(IOMasterPort))
        return KERN_FAILURE;
    return WK_SYSTEM(IOMasterPort)(bootstrapPort, mainPort);
}
#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------------
// IOKit HID event system client (newer HID API) — used to read the pointer scroll-acceleration curve.
// Absent on 10.9; returning null/no-op leaves WebKit on the default acceleration curve.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("IOKit", void, IOHIDEventSystemClientActivate, (void *client))
{
    (void)client;
}

WK_POLYFILL_ABSENT("IOKit", void *, IOHIDEventSystemClientCopyServiceForRegistryID, (void *client, uint64_t registryID))
{
    (void)client; (void)registryID;
    return NULL;
}

WK_POLYFILL_ABSENT("IOKit", void, IOHIDEventSystemClientSetDispatchQueue, (void *client, void *queue))
{
    (void)client; (void)queue;
}

// IOHIDEventGetScrollMomentum (10.9's IOKit lacks this one; the sibling IOHIDEvent accessors
// IOHIDEventGetFloatValue/GetTimeStamp/GetSenderID/GetType ARE present and link to the real
// symbols). Momentum-phase bits aren't reported through this API on 10.9; returning 0 (no bits)
// is the honest answer — scroll deltas still come through the present IOHIDEventGetFloatValue path.
WK_POLYFILL_ABSENT("IOKit", unsigned char, IOHIDEventGetScrollMomentum, (void *event))
{
    (void)event;
    return 0;
}
