// The web-content side of the `browser` namespace WebKit gives Safari 7 legacy extensions: it installs
// LegacyExtensionAPI.js in each extension's content-script world and in the extension's own pages loaded
// in this process, and connects them to the UI process's LegacyExtensionHost router.
//
// Safari 7's injected bundle registers each extension's content scripts in a script world of its own
// through WKBundleAddUserScript; the scripts' safari-extension:// URLs name the extension a world belongs to.
// The UI process gives other web views the same content in content worlds of their own.

#pragma once

#include "MessageReceiver.h"
#include <WebCore/FrameIdentifier.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <WebCore/UserStyleSheet.h>
#include <wtf/Forward.h>
#include <wtf/Vector.h>
#include <wtf/WeakHashMap.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class DOMWrapperWorld;
class Document;
class WeakPtrImplWithEventTargetData;
}

namespace WebKit {

class WebFrame;
class WebProcess;

class LegacyExtensionContent final : public IPC::MessageReceiver {
public:
    static LegacyExtensionContent& singleton();

    void ref() const final { }
    void deref() const final { }

    void initialize(WebProcess&);

    // Safari's bundle changed its extensions' content: the UI process learns what it now is, as JSON.
    void bundleUserContentDidChange();
    // Safari withdraws an extension's world when it disables or reloads the extension: once no user
    // content controller holds user content in a content-script world, its contexts are inert.
    bool isContextWorldLive(WebCore::DOMWrapperWorld&) const;
    void didClearWindowObjectForFrame(WebFrame&, WebCore::DOMWrapperWorld&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    // tabs.insertCSS and removeCSS: removal matches an extension's own sheets of the document by their
    // source, as upstream's dynamically injected style sheets are matched.
    void insertStyleSheet(WebCore::Document&, const String& extensionKey, WebCore::UserStyleSheet&&);
    void removeStyleSheets(WebCore::Document&, const String& extensionKey, const String& source);

private:
    struct InjectedStyleSheet {
        String extensionKey;
        WebCore::UserStyleSheet styleSheet;
    };

    void deliver(WebCore::FrameIdentifier, std::optional<WebCore::ScriptExecutionContextIdentifier>, String&& extensionKey, String&& message);
    void evictMemoryCache();

    WebCore::DOMWrapperWorld* contentScriptWorld(const String& extensionKey) const;
    String extensionKeyForWorld(WebFrame&, WebCore::DOMWrapperWorld&) const;
    void replyWithoutContext(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, const String& extensionKey, const String& message);

    void reportBundleUserContent();

    bool m_bundleUserContentReportIsScheduled { false };
    String m_reportedBundleUserContent { "[]"_s };
    WeakHashMap<WebCore::Document, Vector<InjectedStyleSheet>, WebCore::WeakPtrImplWithEventTargetData> m_injectedStyleSheets;
};

} // namespace WebKit
