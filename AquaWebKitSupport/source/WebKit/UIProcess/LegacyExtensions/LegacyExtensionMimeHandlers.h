// The mimeHandler API of Safari 7 extensions: the document viewers extensions declare in Info.plist under a
// WebExtension manifest's `mime_types_handler` key, with its keys (each MIME type's `handler_url`, a path in the
// extension, and `can_embed`), and the options extensions set for them.
//
// Each MIME type goes to one handler: that of the most recently loaded extension that declares the type and has
// not disabled it, Safari loading its extensions in the order they were installed. application/pdf is the one
// type an extension can handle, as in Chrome. Web content processes receive the handlers as JSON.

#pragma once

#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/StringHash.h>

namespace WebKit {

class WebProcessProxy;

class LegacyExtensionMimeHandlers {
public:
    static LegacyExtensionMimeHandlers& singleton();

    void extensionDidLoad(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& mimeTypesHandler);
    void extensionDidUnload(const String& extensionKey);

    // getMimeHandlerOptions and setMimeHandlerOptions: `{ enabled }`, which persists.
    Ref<JSON::Object> options(const String& extensionKey, const String& mimeType);
    void setOptions(const String& extensionKey, const String& mimeType, bool enabled);

    void sendHandlers(WebProcessProxy&);

private:
    struct Handler {
        String mimeType;
        URL handlerURL;
        bool canEmbed { false };
    };
    struct Extension {
        String extensionKey;
        Vector<Handler> handlers;
    };

    HashMap<String, bool, ASCIICaseInsensitiveHash>& disabledTypes(const String& extensionKey);
    void update();

    // Loaded extensions, the earliest loaded first.
    Vector<Extension> m_extensions;
    // Each extension's options, by extension key, as the MIME types it disabled.
    HashMap<String, HashMap<String, bool, ASCIICaseInsensitiveHash>> m_disabledTypes;
    String m_handlersJSON { "[]"_s };
};

} // namespace WebKit
