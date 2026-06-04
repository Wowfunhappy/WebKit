// Stubbed for macOS 10.9 backport.
// Exception: UserMediaPermissionRequestProxy::create() — the cross-platform definition in
// UserMediaPermissionRequestProxy.cpp is gated `#if !PLATFORM(COCOA)`, so on Cocoa it must come from
// the Mac file. The rest of the Mac permission UI stays stubbed (getUserMedia auto-grant path); only
// the trivial factory is provided so the WebKit framework links with ENABLE(MEDIA_STREAM).
#include "config.h"

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

#include "UserMediaPermissionRequestProxy.h"
#include "UserMediaPermissionRequestManagerProxy.h"
#include <WebCore/CaptureDevice.h>
#include <WebCore/MediaStreamRequest.h>
#include <WebCore/SecurityOrigin.h>

namespace WebKit {
using namespace WebCore;

Ref<UserMediaPermissionRequestProxy> UserMediaPermissionRequestProxy::create(UserMediaPermissionRequestManagerProxy& manager, std::optional<WebCore::UserMediaRequestIdentifier> userMediaID, WebCore::FrameIdentifier mainFrameID, FrameInfoData&& frameInfo, Ref<WebCore::SecurityOrigin>&& userMediaDocumentOrigin, Ref<WebCore::SecurityOrigin>&& topLevelDocumentOrigin, Vector<WebCore::CaptureDevice>&& audioDevices, Vector<WebCore::CaptureDevice>&& videoDevices, WebCore::MediaStreamRequest&& request, CompletionHandler<void(bool)>&& decisionCompletionHandler)
{
    return adoptRef(*new UserMediaPermissionRequestProxy(manager, userMediaID, mainFrameID, WTF::move(frameInfo), WTF::move(userMediaDocumentOrigin), WTF::move(topLevelDocumentOrigin), WTF::move(audioDevices), WTF::move(videoDevices), WTF::move(request), WTF::move(decisionCompletionHandler)));
}

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
