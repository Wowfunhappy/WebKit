// The proxy API of Safari 7 extensions: Chromium's proxy.settings, a ChromeSetting whose value is a ProxyConfig. The
// value that applies reaches every network process and the Safari process's own loads, where
// CocoaCurlProxyConfiguration routes them by it; with none, loads take the system's proxy settings.
//
// The value is that of the most recently loaded extension that set it, Safari loading its extensions in the order
// they were installed, and `{ mode: "system" }` when none did, as LegacyExtensionPrivacy's settings are. An
// extension's value persists until the extension clears it, and applies while the extension is loaded. Only the
// regular scope is supported, as in Firefox.

#pragma once

#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/JSONValues.h>
#include <wtf/Vector.h>
#include <wtf/text/StringHash.h>

namespace WebKit {

class NetworkProcessProxy;

class LegacyExtensionProxy {
public:
    static LegacyExtensionProxy& singleton();

    void extensionDidLoad(const String& extensionKey);
    void extensionDidUnload(const String& extensionKey);

    // `{ value, levelOfControl }`, as the extension sees the setting.
    Ref<JSON::Object> details(const String& extensionKey);
    // The error Chromium's set() reports for an invalid value, or null. `pacData` is the script a pac_script value's
    // URL names when the extension read it itself: its own resources and data: URLs are no network load's.
    String set(const String& extensionKey, const JSON::Object& value, const String& pacData);
    void clear(const String& extensionKey);

    void sendSettings(NetworkProcessProxy&);
    // Called when the value or the extension controlling it changes.
    void setChangeObserver(Function<void()>&& observer) { m_changeObserver = WTF::move(observer); }

private:
    // The value as get() reports it, and the configuration CocoaCurlProxyConfiguration reads.
    struct Setting {
        RefPtr<JSON::Object> value;
        String configuration;
    };
    std::optional<Setting>& setting(const String& extensionKey);
    void save(const String& extensionKey);
    String controllingExtension();
    String configuration();
    void update();

    HashMap<String, std::optional<Setting>> m_settings;
    // Loaded extensions, the earliest loaded first.
    Vector<String> m_loadedExtensions;
    std::optional<std::pair<String, String>> m_applied;
    Function<void()> m_changeObserver;
};

} // namespace WebKit
