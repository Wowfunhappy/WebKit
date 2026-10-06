// The com.widevine.alpha key system is served by Google's own Widevine CDM, which is not
// redistributable and so is fetched at runtime from the update service Firefox's Gecko Media
// Plugins use. The module is retargeted at this host (WidevineCdmImage) and installed in the
// user's library, from where the process that plays the media loads it -- WebKitLegacy in its own
// process, and a WebKit web process through a sandbox extension the UIProcess issues for the
// installed directory.

#pragma once

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

struct WidevineCdmModule {
    String directory;
    String path;
    String version;
};

class WidevineCdmInstaller {
    WTF_MAKE_NONCOPYABLE(WidevineCdmInstaller);
public:
    WEBCORE_EXPORT static WidevineCdmInstaller& singleton();

    // Answers with the installed module, installing it first if this is the first call that needs
    // it. Called on the main thread; the callback runs there too, once the work is done.
    WEBCORE_EXPORT void ensureModule(CompletionHandler<void(const std::optional<WidevineCdmModule>&)>&&);

private:
    friend class NeverDestroyed<WidevineCdmInstaller>;
    WidevineCdmInstaller() = default;

    void provision();
    void finish(std::optional<WidevineCdmModule>&&);

    Vector<CompletionHandler<void(const std::optional<WidevineCdmModule>&)>> m_pendingCallbacks;
    std::optional<WidevineCdmModule> m_module;
    bool m_isProvisioning { false };
    bool m_hasProvisioned { false };
};

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
