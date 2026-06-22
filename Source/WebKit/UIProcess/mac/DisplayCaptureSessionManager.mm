// macOS 10.9 backport: the full screen-capture (getDisplayMedia) session manager needs
// ScreenCaptureKit (12.3+), so provide a minimal DisplayCaptureSessionManager — a real singleton with
// no-op display capture (screen sharing is unavailable on 10.9; isAvailable() returns false) — so the
// ENABLE(MEDIA_STREAM) getUserMedia path links. checkSandboxRequirementForType() and the other
// permission helpers come from the real MediaPermissionUtilities.mm.
#include "config.h"

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

#include "DisplayCaptureSessionManager.h"
#include "MediaPermissionUtilities.h"
#include "SandboxUtilities.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/spi/darwin/SandboxSPI.h>
#include <wtf/text/ASCIILiteral.h>

namespace WebKit {

DisplayCaptureSessionManager::DisplayCaptureSessionManager() = default;
DisplayCaptureSessionManager::~DisplayCaptureSessionManager() = default;

DisplayCaptureSessionManager& DisplayCaptureSessionManager::singleton()
{
    static NeverDestroyed<DisplayCaptureSessionManager> manager;
    return manager.get();
}

bool DisplayCaptureSessionManager::isAvailable()
{
    // Screen capture (getDisplayMedia) requires ScreenCaptureKit (macOS 12.3+); unavailable on 10.9.
    return false;
}

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
