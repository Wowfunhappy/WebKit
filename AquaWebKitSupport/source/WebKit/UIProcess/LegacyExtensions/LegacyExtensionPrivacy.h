// The privacy API of Safari 7 extensions: browser settings an extension controls, as Chrome's ChromeSettings.
// `network.networkPredictionEnabled` covers the DNS prefetching and the preconnections pages ask for, and
// `websites.hyperlinkAuditingEnabled` the pings of <a ping>; network processes enforce both.
//
// A setting's value is that of the most recently loaded extension that set it, Safari loading its extensions in
// the order they were installed, and true, the browser's, when none did. An extension's value persists until the
// extension clears it, and applies while the extension is loaded.

#pragma once

#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/Vector.h>
#include <wtf/text/StringHash.h>

namespace WebKit {

class NetworkProcessProxy;

class LegacyExtensionPrivacy {
public:
    static LegacyExtensionPrivacy& singleton();

    static bool isSetting(const String& name);

    void extensionDidLoad(const String& extensionKey);
    void extensionDidUnload(const String& extensionKey);

    // `{ value, levelOfControl }`, as the extension sees the setting.
    Ref<JSON::Object> details(const String& extensionKey, const String& name);
    void set(const String& extensionKey, const String& name, bool value);
    void clear(const String& extensionKey, const String& name);

    void sendSettings(NetworkProcessProxy&);
    // Called with a setting's name when its value or the extension controlling it changes.
    void setChangeObserver(Function<void(const String& name)>&& observer) { m_changeObserver = WTF::move(observer); }

private:
    HashMap<String, bool>& values(const String& extensionKey);
    void save(const String& extensionKey);
    // The extension controlling the setting, or null.
    String controllingExtension(const String& name);
    bool value(const String& name);
    void update();

    // Each extension's values, by extension key and then setting name.
    HashMap<String, HashMap<String, bool>> m_values;
    // Loaded extensions, the earliest loaded first.
    Vector<String> m_loadedExtensions;
    // Each setting's value and controlling extension as last applied.
    HashMap<String, std::pair<bool, String>> m_applied;
    Function<void(const String&)> m_changeObserver;
};

} // namespace WebKit
