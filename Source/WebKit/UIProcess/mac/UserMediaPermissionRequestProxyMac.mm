// Stubbed for MAVERICKS_BACKPORT.
// Exception: UserMediaPermissionRequestProxy::create() — the cross-platform definition in
// UserMediaPermissionRequestProxy.cpp is gated `#if !PLATFORM(COCOA)`, so on Cocoa it must come from
// the Mac file. The rest of the Mac permission UI stays stubbed (consent is the alertForPermission sheet); only
// the trivial factory is provided so the WebKit framework links with ENABLE(MEDIA_STREAM).
#include "config.h"

// MAVERICKS_BACKPORT: compile this stub only on Cocoa with MEDIA_STREAM (matches where the cross-platform create() is gated out).
#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

// MAVERICKS_BACKPORT: pull only the base proxy/manager + WebCore device/request/origin types the trivial factory needs.
#include "UserMediaPermissionRequestProxy.h"
#include "UserMediaPermissionRequestManagerProxy.h"
#include <WebCore/CaptureDevice.h>
#include <WebCore/MediaStreamRequest.h>
#include <WebCore/SecurityOrigin.h>

namespace WebKit {
using namespace WebCore;

// MAVERICKS_BACKPORT: factory returns a plain UserMediaPermissionRequestProxy (no Mac subclass); the cross-platform create() in the .cpp is gated out on Cocoa, so it must be provided here.
Ref<UserMediaPermissionRequestProxy> UserMediaPermissionRequestProxy::create(UserMediaPermissionRequestManagerProxy& manager, std::optional<WebCore::UserMediaRequestIdentifier> userMediaID, WebCore::FrameIdentifier mainFrameID, FrameInfoData&& frameInfo, Ref<WebCore::SecurityOrigin>&& userMediaDocumentOrigin, Ref<WebCore::SecurityOrigin>&& topLevelDocumentOrigin, Vector<WebCore::CaptureDevice>&& audioDevices, Vector<WebCore::CaptureDevice>&& videoDevices, WebCore::MediaStreamRequest&& request, CompletionHandler<void(bool)>&& decisionCompletionHandler)
{
    return adoptRef(*new UserMediaPermissionRequestProxy(manager, userMediaID, mainFrameID, WTF::move(frameInfo), WTF::move(userMediaDocumentOrigin), WTF::move(topLevelDocumentOrigin), WTF::move(audioDevices), WTF::move(videoDevices), WTF::move(request), WTF::move(decisionCompletionHandler)));
}

} // namespace WebKit

// MAVERICKS_BACKPORT: closes the stub's COCOA/MEDIA_STREAM guard.
#endif // PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
