// MAVERICKS_BACKPORT: the full screen-capture (getDisplayMedia) session manager needs
// ScreenCaptureKit (12.3+), so provide a minimal DisplayCaptureSessionManager — a real singleton with
// no-op display capture (screen sharing is unavailable on 10.9; isAvailable() returns false) — so the
// ENABLE(MEDIA_STREAM) getUserMedia path links. checkSandboxRequirementForType() and the other
// permission helpers come from the real MediaPermissionUtilities.mm.
#include "config.h"

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

// MAVERICKS_BACKPORT: minimal include set for the no-op display-capture manager (no ScreenCaptureKit/WebCore capture headers; see file header).
#include "DisplayCaptureSessionManager.h"
#include "MediaPermissionUtilities.h"
#include "SandboxUtilities.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/spi/darwin/SandboxSPI.h>
#include <wtf/text/ASCIILiteral.h>

namespace WebKit {

// MAVERICKS_BACKPORT: trivial ctor/dtor for the no-op display-capture manager (see file header).
DisplayCaptureSessionManager::DisplayCaptureSessionManager() = default;
DisplayCaptureSessionManager::~DisplayCaptureSessionManager() = default;

// MAVERICKS_BACKPORT: minimal singleton for the no-op display-capture manager (see file header).
DisplayCaptureSessionManager& DisplayCaptureSessionManager::singleton()
{
    static NeverDestroyed<DisplayCaptureSessionManager> manager;
    // MAVERICKS_BACKPORT: return the held instance (no main-run-loop assert / ScreenCaptureKit deps).
    return manager.get();
}

// MAVERICKS_BACKPORT: screen capture (getDisplayMedia) requires ScreenCaptureKit (macOS 12.3+); always unavailable on 10.9.
bool DisplayCaptureSessionManager::isAvailable()
{
    // MAVERICKS_BACKPORT: Screen capture (getDisplayMedia) requires ScreenCaptureKit (macOS 12.3+); unavailable on 10.9.
    return false;
}

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
