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

DisplayCaptureSessionManager& DisplayCaptureSessionManager::singleton()
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     ASSERT(isMainRunLoop());
// (end MAVERICKS_BACKPORT restored block)
    static NeverDestroyed<DisplayCaptureSessionManager> manager;
    // MAVERICKS_BACKPORT: return the held instance (no main-run-loop assert / ScreenCaptureKit deps).
    return manager.get();
}

// MAVERICKS_BACKPORT: screen capture (getDisplayMedia) requires ScreenCaptureKit (macOS 12.3+); always unavailable on 10.9.
bool DisplayCaptureSessionManager::isAvailable()
{
    // MAVERICKS_BACKPORT: Screen capture (getDisplayMedia) requires ScreenCaptureKit (macOS 12.3+); unavailable on 10.9.
    return false;
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#endif
}

#if HAVE(SCREEN_CAPTURE_KIT)
static WebCore::DisplayCapturePromptType NODELETE toScreenCaptureKitPromptType(UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType promptType)
{
    if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::Screen)
        return WebCore::DisplayCapturePromptType::Screen;
    if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::Window)
        return WebCore::DisplayCapturePromptType::Window;
    if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::UserChoose)
        return WebCore::DisplayCapturePromptType::UserChoose;

    ASSERT_NOT_REACHED();
    return WebCore::DisplayCapturePromptType::Screen;
}
#endif

void DisplayCaptureSessionManager::promptForGetDisplayMedia(UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType promptType, WebPageProxy& page, const WebCore::SecurityOriginData& origin, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&& completionHandler)
{
    if (useMockCaptureDevices()) {
        if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::Window)
            showWindowPicker(origin, WTF::move(completionHandler));
        else
            showScreenPicker(origin, WTF::move(completionHandler));
        return;
    }

#if HAVE(SCREEN_CAPTURE_KIT)
    ASSERT(isAvailable());

    if (!isAvailable() || !completionHandler) {
        completionHandler(std::nullopt);
        return;
    }

    if (WebCore::ScreenCaptureKitSharingSessionManager::isAvailable()) {
        if (!protect(page.preferences())->useGPUProcessForDisplayCapture()) {
            WebCore::ScreenCaptureKitSharingSessionManager::singleton().promptForGetDisplayMedia(toScreenCaptureKitPromptType(promptType), WTF::move(completionHandler));
            return;
        }

        Ref gpuProcess = protect(page.configuration().processPool())->ensureGPUProcess();
        gpuProcess->updateSandboxAccess(false, false, true);
        gpuProcess->promptForGetDisplayMedia(toScreenCaptureKitPromptType(promptType), WTF::move(completionHandler));
        return;
    }

    if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::Screen) {
        showScreenPicker(origin, WTF::move(completionHandler));
        return;
    }

    if (promptType == UserMediaPermissionRequestProxy::UserMediaDisplayCapturePromptType::Window) {
        showWindowPicker(origin, WTF::move(completionHandler));
        return;
    }

#if HAVE(WINDOW_CAPTURE)
    alertForGetDisplayMedia(page, origin, [this, origin, completionHandler = WTF::move(completionHandler)] (DisplayCaptureSessionManager::CaptureSessionType sessionType) mutable {
        if (sessionType == CaptureSessionType::None) {
            completionHandler(std::nullopt);
            return;
        }

        if (sessionType == CaptureSessionType::Screen)
            showScreenPicker(origin, WTF::move(completionHandler));
        else
            showWindowPicker(origin, WTF::move(completionHandler));
    });
#else
    completionHandler(std::nullopt);
#endif // HAVE(WINDOW_CAPTURE)

#endif // HAVE(SCREEN_CAPTURE_KIT)
}

void DisplayCaptureSessionManager::cancelGetDisplayMediaPrompt(WebPageProxy& page)
{
#if HAVE(SCREEN_CAPTURE_KIT)
    ASSERT(isAvailable());

    if (!isAvailable() || !WebCore::ScreenCaptureKitSharingSessionManager::isAvailable())
        return;

    if (!protect(page.preferences())->useGPUProcessForDisplayCapture()) {
        WebCore::ScreenCaptureKitSharingSessionManager::singleton().cancelGetDisplayMediaPrompt();
        return;
    }

    RefPtr gpuProcess = page.configuration().processPool().gpuProcess();
    if (!gpuProcess)
        return;

    gpuProcess->cancelGetDisplayMediaPrompt();
#endif
MAVERICKS_BACKPORT */
}

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
