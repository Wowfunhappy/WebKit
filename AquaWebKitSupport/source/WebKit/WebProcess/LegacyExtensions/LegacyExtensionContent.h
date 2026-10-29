// The web-content side of the `browser` namespace WebKit gives Safari 7 legacy extensions: it installs
// LegacyExtensionAPI.js in each extension's content-script world and in the extension's own pages loaded
// in this process, and connects them to the UI process's LegacyExtensionHost router.
//
// Safari 7's injected bundle registers each extension's content scripts in a script world of its own
// through WKBundleAddUserScript; the scripts' safari-extension:// URLs name the extension a world belongs to.
// Another client gives its web views an extension's content in a content world of the extension's own, with
// the same URLs.

#pragma once

#include "MessageReceiver.h"
#include <WebCore/FrameIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ScriptExecutionContextIdentifier.h>
#include <WebCore/UserStyleSheet.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/Vector.h>
#include <wtf/WeakHashMap.h>
#include <wtf/text/WTFString.h>

namespace IPC {
class SharedBufferReference;
}

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

    void didAddOriginAccessAllowListEntry(const String&, const String&, const String&, bool);
    void didRemoveOriginAccessAllowListEntry(const String&, const String&, const String&, bool);
    void didResetOriginAccessAllowLists();
    void replayOriginAccessAllowLists(IPC::Connection&) const;

    // Safari withdraws an extension's user content when it disables or reloads the extension: once no user
    // content controller holds user content of the copy of the extension at `root` (any, if empty) in a
    // content-script world, the world's contexts of that copy are inert, and the router ends their ports and
    // messages.
    bool isContextLive(WebCore::DOMWrapperWorld&, const String& root = { }) const;
    // User content was added or removed: also tells the router the roots of the extensions whose user content
    // the process holds.
    void userContentDidChange();
    void didClearWindowObjectForFrame(WebFrame&, WebCore::DOMWrapperWorld&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    // tabs.insertCSS and removeCSS: removal matches an extension's own sheets of the document by their
    // source, as upstream's dynamically injected style sheets are matched.
    void insertStyleSheet(WebCore::Document&, const String& extensionKey, WebCore::UserStyleSheet&&);
    void removeStyleSheets(WebCore::Document&, const String& extensionKey, const String& source);

private:
    struct OriginAccessGrant {
        String sourceOrigin;
        String destinationProtocol;
        String destinationHost;
        bool allowDestinationSubdomains;
        bool operator==(const OriginAccessGrant&) const = default;
    };

    struct InjectedStyleSheet {
        String extensionKey;
        WebCore::UserStyleSheet styleSheet;
    };

    void deliver(WebCore::FrameIdentifier, std::optional<WebCore::ScriptExecutionContextIdentifier>, String&& extensionKey, String&& message, IPC::SharedBufferReference&&);
    void evictMemoryCache();
    void setMimeHandlers(String&&);
    void invalidateExtensionPage(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier);
    void setPrintsBackgrounds(WebCore::PageIdentifier, bool);

    WebCore::DOMWrapperWorld* contentScriptWorld(const String& extensionKey) const;
    String extensionKeyForWorld(WebFrame&, WebCore::DOMWrapperWorld&) const;
    void replyWithoutContext(WebCore::FrameIdentifier, WebCore::ScriptExecutionContextIdentifier, const String& extensionKey, const String& message);

    WeakHashMap<WebCore::Document, Vector<InjectedStyleSheet>, WebCore::WeakPtrImplWithEventTargetData> m_injectedStyleSheets;
    Vector<String> m_reportedUserContentExtensionRoots;
    Vector<OriginAccessGrant> m_originAccessGrants;
};

} // namespace WebKit
