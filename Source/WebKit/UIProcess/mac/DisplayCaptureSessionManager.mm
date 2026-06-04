// macOS 10.9 backport: the full screen-capture (getDisplayMedia) session manager needs
// ScreenCaptureKit (12.3+), so it stays stubbed. But ENABLE(MEDIA_STREAM) compiles the getUserMedia
// permission path, which links against DisplayCaptureSessionManager::singleton() and
// checkSandboxRequirementForType(). Provide minimal definitions here so the WebKit framework links:
//  - DisplayCaptureSessionManager: a real singleton with no-op display capture (screen sharing is
//    unavailable on 10.9; isAvailable() returns false).
//  - checkSandboxRequirementForType: the real sandbox_check-based implementation (no AVFoundation),
//    extracted from the (10.9-excluded, AVFoundation-heavy) MediaPermissionUtilities.mm.
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

bool checkSandboxRequirementForType(MediaPermissionType type)
{
    auto checkFunction = [](ASCIILiteral operation) {
        if (!currentProcessIsSandboxed())
            return true;

        int result = sandbox_check(getpid(), operation, static_cast<enum sandbox_filter_type>(SANDBOX_CHECK_NO_REPORT | SANDBOX_FILTER_NONE));
        if (result == -1)
            WTFLogAlways("Error checking '%s' sandbox access, errno=%ld", operation.characters(), (long)errno);
        return !result;
    };

    switch (type) {
    case MediaPermissionType::Audio:
        static bool isAudioEntitled = checkFunction("device-microphone"_s);
        return isAudioEntitled;
    case MediaPermissionType::Video:
        static bool isVideoEntitled = checkFunction("device-camera"_s);
        return isVideoEntitled;
    }
    return true;
}

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
