// Mac page support for QuickTime Player URL hand-offs and Widevine CDM installation.

#import "config.h"
#import "WebPageProxy.h"

#if PLATFORM(MAC)

#import "MessageSenderInlines.h"
#import "WebProcessProxy.h"
#import <AppKit/AppKit.h>

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
#import "MediaKeySystemPermissionRequestProxy.h"
#import "SandboxExtension.h"
#import "WebProcessMessages.h"
#import <WebCore/WidevineCdmInstaller.h>
#endif

namespace WebKit {

// Navigation policy and extension hand-offs use LaunchServices to deliver a GetURL Apple event.
bool WebPageProxy::openURLInMediaPlayer(const URL& url, const String& application)
{
    if (!url.protocolIsInHTTPFamily() || application.isEmpty())
        return false;

    return [[NSWorkspace sharedWorkspace] openURLs:@[url.createNSURL().get()] withAppBundleIdentifier:application.createNSString().get() options:NSWorkspaceLaunchAsync additionalEventParamDescriptor:nil launchIdentifiers:nullptr];
}

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
// The page asked for com.widevine.alpha and the client allowed it. Google's CDM is not
// redistributable, so it is installed at runtime the first time a page needs it; the web process is
// told where it landed before the request is allowed, because what answers
// requestMediaKeySystemAccess() next is whether that process can load it.
void WebPageProxy::allowMediaKeySystemRequestWithWidevineCdm(Ref<MediaKeySystemPermissionRequestProxy>&& request)
{
    WebCore::WidevineCdmInstaller::singleton().ensureModule([weakThis = WeakPtr { *this }, request = WTF::move(request)](const std::optional<WebCore::WidevineCdmModule>& module) mutable {
        RefPtr protectedThis = weakThis.get();
        std::optional<SandboxExtension::Handle> handle;
        if (module) {
            // The extension covers the module's whole directory, which is what the gap library
            // beside it needs too.
            handle = SandboxExtension::createHandleWithoutResolvingPath(module->directory, SandboxExtension::Type::ReadOnly);
        }
        if (!protectedThis || !handle) {
            request->deny();
            return;
        }

        protect(protectedThis->legacyMainFrameProcess())->send(Messages::WebProcess::SetWidevineCdmModule(module->path, WTF::move(*handle)), 0);
        request->allow();
    });
}
#endif

} // namespace WebKit

#endif // PLATFORM(MAC)
