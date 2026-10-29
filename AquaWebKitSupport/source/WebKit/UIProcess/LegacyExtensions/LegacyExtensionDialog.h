// A JavaScript dialog Safari 7 runs in a synchronous C UI-client callback, scoped to that callback. The panel the
// callback opens is found on the next main run loop turn, as WebAutomationSession::willShowJavaScriptDialog checks
// for its client's dialog, and an extension's answer presses that panel's own button.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CheckedPtr.h>
#include <wtf/Expected.h>
#include <wtf/JSONValues.h>
#include <wtf/Ref.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class WebPageProxy;

class LegacyExtensionDialog final : public CanMakeWeakPtr<LegacyExtensionDialog>, public CanMakeCheckedPtr<LegacyExtensionDialog> {
    WTF_MAKE_TZONE_ALLOCATED(LegacyExtensionDialog);
    WTF_MAKE_NONCOPYABLE(LegacyExtensionDialog);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(LegacyExtensionDialog);
public:
    enum class Type : uint8_t { Alert, Confirm, Prompt, BeforeUnload };

    // The dialog of a callback Safari answers synchronously, or null for any other client or callback.
    static std::unique_ptr<LegacyExtensionDialog> createForSynchronousCallback(WebPageProxy&, Type, bool isSynchronous, const String& message, const String& defaultText = { });

    LegacyExtensionDialog(WebPageProxy&, Type, const String& message, const String& defaultText);
    ~LegacyExtensionDialog();

    WebPageProxy& page() const { return m_page; }
    bool isOpen() const;

    static Expected<void, String> answer(WebPageProxy&, const String& extensionKey, const LegacyExtensions::WebsiteAccess&, const JSON::Object&);

private:
    void findPanel();
    Expected<void, String> pressButton(bool accept, const String& text);

    struct Platform;
    Ref<WebPageProxy> m_page;
    Type m_type;
    String m_message;
    String m_defaultText;
    LegacyExtensionDialog* m_previous;
    std::unique_ptr<Platform> m_platform;
    bool m_answered { false };
};

} // namespace WebKit
