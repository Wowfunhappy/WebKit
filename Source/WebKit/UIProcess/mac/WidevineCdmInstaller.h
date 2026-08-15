// MAVERICKS_BACKPORT: com.widevine.alpha is served by Google's own Widevine CDM, which is not
// redistributable and so is fetched at runtime from the update service Firefox's Gecko Media
// Plugins use. The module is retargeted at this host (WidevineCdmImage) and installed in the
// user's library, where a sandbox extension lets a web process load it.

#pragma once

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include "SandboxExtension.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

struct WidevineCdmModule {
    String directory;
    String path;
    String version;
};

class WidevineCdmInstaller {
    WTF_MAKE_NONCOPYABLE(WidevineCdmInstaller);
public:
    static WidevineCdmInstaller& singleton();

    // Answers with the installed module, installing it first if this is the first call that needs
    // it. Called on the main thread; the callback runs there too, once the work is done.
    void ensureModule(CompletionHandler<void(const std::optional<WidevineCdmModule>&)>&&);

    // A read extension for the module's directory, which covers the module and the gap library it
    // loads from beside itself.
    static std::optional<SandboxExtension::Handle> createHandleForModule(const WidevineCdmModule&);

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

} // namespace WebKit

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
