#include "config.h"
#include "LegacyExtensionProxy.h"

#include "LegacyExtensionInfoPlist.h"
#include "LegacyExtensionNetworkMessages.h"
#include "Logging.h"
#include "NetworkProcessProxy.h"
#include <WebCore/CocoaCurlProxyConfiguration.h>
#include <wtf/FileSystem.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>

namespace WebKit {

using namespace WebCore;

LegacyExtensionProxy& LegacyExtensionProxy::singleton()
{
    static NeverDestroyed<LegacyExtensionProxy> proxy;
    return proxy;
}

static String settingsPath(const String& extensionKey)
{
    return FileSystem::pathByAppendingComponent(LegacyExtensions::storageDirectory(extensionKey), "ProxySettings.json"_s);
}

std::optional<LegacyExtensionProxy::Setting>& LegacyExtensionProxy::setting(const String& extensionKey)
{
    return m_settings.ensure(extensionKey, [&]() -> std::optional<Setting> {
        auto contents = FileSystem::readEntireFile(settingsPath(extensionKey));
        auto json = contents ? JSON::Value::parseJSON(String::fromUTF8(contents->span())) : nullptr;
        RefPtr object = json ? json->asObject() : nullptr;
        RefPtr value = object ? object->getObject("value"_s) : nullptr;
        auto configuration = object ? object->getString("configuration"_s) : String();
        if (!value || configuration.isNull())
            return std::nullopt;
        return Setting { WTF::move(value), WTF::move(configuration) };
    }).iterator->value;
}

void LegacyExtensionProxy::save(const String& extensionKey)
{
    auto path = settingsPath(extensionKey);
    auto& current = setting(extensionKey);
    if (!current) {
        FileSystem::deleteFile(path);
        return;
    }
    auto object = JSON::Object::create();
    object->setObject("value"_s, *current->value);
    object->setString("configuration"_s, current->configuration);
    FileSystem::makeAllDirectories(FileSystem::parentPath(path));
    auto json = object->toJSONString().utf8();
    if (FileSystem::overwriteEntireFile(path, byteCast<uint8_t>(json.span())) != json.length())
        RELEASE_LOG_ERROR(Extensions, "Unable to save the proxy settings of extension %" PUBLIC_LOG_STRING, extensionKey.utf8().data());
}

void LegacyExtensionProxy::extensionDidLoad(const String& extensionKey)
{
    m_loadedExtensions.removeAll(extensionKey);
    m_loadedExtensions.append(extensionKey);
    update();
}

void LegacyExtensionProxy::extensionDidUnload(const String& extensionKey)
{
    if (m_loadedExtensions.removeAll(extensionKey))
        update();
}

String LegacyExtensionProxy::controllingExtension()
{
    for (size_t index = m_loadedExtensions.size(); index; --index) {
        auto extensionKey = m_loadedExtensions[index - 1];
        if (setting(extensionKey))
            return extensionKey;
    }
    return { };
}

String LegacyExtensionProxy::configuration()
{
    auto extensionKey = controllingExtension();
    return extensionKey.isNull() ? emptyString() : setting(extensionKey)->configuration;
}

Ref<JSON::Object> LegacyExtensionProxy::details(const String& extensionKey)
{
    auto controller = controllingExtension();
    auto details = JSON::Object::create();
    if (controller.isNull()) {
        auto value = JSON::Object::create();
        value->setString("mode"_s, "system"_s);
        details->setObject("value"_s, WTF::move(value));
        details->setString("levelOfControl"_s, "controllable_by_this_extension"_s);
        return details;
    }
    details->setObject("value"_s, *setting(controller)->value);
    details->setString("levelOfControl"_s, controller == extensionKey ? "controlled_by_this_extension"_s : "controlled_by_other_extensions"_s);
    return details;
}

// Chromium's GetProxyServer: the scheme defaults to http, the port to the scheme's. QUIC proxies, which curl
// reaches only through an HTTP/3 build this port does not have, are not supported.
static Expected<Ref<JSON::Object>, String> normalizedServer(const JSON::Object& server)
{
    auto scheme = server.getString("scheme"_s);
    if (scheme != "socks4"_s && scheme != "socks5"_s && scheme != "https"_s && scheme != "quic"_s)
        scheme = scheme == "socks"_s ? "socks4"_s : "http"_s;
    if (scheme == "quic"_s)
        return makeUnexpected(makeString("Proxy scheme '"_s, scheme, "' is not supported."_s));
    auto host = server.getString("host"_s);
    if (host.isEmpty() || !host.containsOnlyASCII() || host.contains(' '))
        return makeUnexpected(makeString("Invalid 'rules.???.host' entry '"_s, host, "'."_s));
    int defaultPort = scheme == "http"_s ? 80 : scheme == "https"_s ? 443 : 1080;
    auto port = server.getInteger("port"_s).value_or(defaultPort);
    if (port <= 0 || port > 65535)
        return makeUnexpected(makeString("Invalid 'rules.???.port' entry '"_s, port, "'."_s));
    auto normalized = JSON::Object::create();
    normalized->setString("scheme"_s, scheme);
    normalized->setString("host"_s, host);
    normalized->setInteger("port"_s, port);
    return normalized;
}

// Chromium's ProxyPrefTransformer::ExtensionToBrowserPref and CreateProxyConfigDict: the value as get() reports it,
// with only the fields its mode reads.
static Expected<Ref<JSON::Object>, String> normalizedValue(const JSON::Object& value)
{
    auto mode = value.getString("mode"_s);
    if (mode != "direct"_s && mode != "auto_detect"_s && mode != "pac_script"_s && mode != "fixed_servers"_s && mode != "system"_s)
        return makeUnexpected("Error at property 'mode': Value must be one of auto_detect, direct, fixed_servers, pac_script, system."_s);
    auto normalized = JSON::Object::create();
    normalized->setString("mode"_s, mode);

    if (mode == "pac_script"_s) {
        RefPtr pacScript = value.getObject("pacScript"_s);
        auto url = pacScript ? pacScript->getString("url"_s) : String();
        auto data = pacScript ? pacScript->getString("data"_s) : String();
        if (!url.containsOnlyASCII())
            return makeUnexpected("'pacScript.url' supports only ASCII URLs (encode URLs in Punycode format)."_s);
        if (!data.containsOnlyASCII())
            return makeUnexpected("'pacScript.data' supports only ASCII code(encode URLs in Punycode format)."_s);
        if (url.isEmpty() && data.isEmpty())
            return makeUnexpected("Proxy mode 'pac_script' requires a 'pacScript' field with either a 'url' field or a 'data' field."_s);
        auto normalizedScript = JSON::Object::create();
        if (!url.isEmpty())
            normalizedScript->setString("url"_s, url);
        else
            normalizedScript->setString("data"_s, data);
        normalizedScript->setBoolean("mandatory"_s, pacScript->getBoolean("mandatory"_s).value_or(false));
        normalized->setObject("pacScript"_s, WTF::move(normalizedScript));
    }

    if (mode == "fixed_servers"_s) {
        RefPtr rules = value.getObject("rules"_s);
        auto normalizedRules = JSON::Object::create();
        bool hasServer = false;
        static constexpr std::array fields { "singleProxy"_s, "proxyForHttp"_s, "proxyForHttps"_s, "proxyForFtp"_s, "fallbackProxy"_s };
        for (auto field : fields) {
            RefPtr server = rules ? rules->getObject(field) : nullptr;
            if (!server)
                continue;
            if (field != fields[0] && normalizedRules->getObject(fields[0]))
                return makeUnexpected(makeString("Proxy rule for "_s, fields[0], " and "_s, field, " set."_s));
            auto normalizedProxy = normalizedServer(*server);
            if (!normalizedProxy)
                return makeUnexpected(normalizedProxy.error());
            normalizedRules->setObject(field, WTF::move(*normalizedProxy));
            hasServer = true;
        }
        if (!hasServer)
            return makeUnexpected("Proxy mode 'fixed_servers' requires a 'rules' field."_s);
        if (RefPtr bypassList = rules->getArray("bypassList"_s)) {
            auto normalizedList = JSON::Array::create();
            for (auto& entry : *bypassList) {
                auto rule = entry->asString();
                if (rule.isNull())
                    return makeUnexpected("'rules.bypassList' must be a list of strings."_s);
                if (!rule.containsOnlyASCII())
                    return makeUnexpected("'rules.bypassList' supports only ASCII URLs (encode URLs in Punycode format)."_s);
                normalizedList->pushString(rule);
            }
            normalizedRules->setArray("bypassList"_s, WTF::move(normalizedList));
        }
        normalized->setObject("rules"_s, WTF::move(normalizedRules));
    }
    return normalized;
}

String LegacyExtensionProxy::set(const String& extensionKey, const JSON::Object& value, const String& pacData)
{
    auto normalized = normalizedValue(value);
    if (!normalized)
        return normalized.error();
    // The configuration runs a script the extension read itself from that script's text.
    Ref configuration = JSON::Object::create();
    for (auto& [key, field] : normalized.value().get())
        configuration->setValue(key, field.copyRef());
    if (RefPtr pacScript = normalized.value()->getObject("pacScript"_s); pacScript && !pacData.isEmpty()) {
        auto script = JSON::Object::create();
        script->setString("data"_s, pacData);
        script->setBoolean("mandatory"_s, pacScript->getBoolean("mandatory"_s).value_or(false));
        configuration->setObject("pacScript"_s, WTF::move(script));
    }
    setting(extensionKey) = Setting { normalized.value().ptr(), configuration->toJSONString() };
    save(extensionKey);
    update();
    return { };
}

void LegacyExtensionProxy::clear(const String& extensionKey)
{
    auto& current = setting(extensionKey);
    if (!current)
        return;
    current = std::nullopt;
    save(extensionKey);
    update();
}

void LegacyExtensionProxy::sendSettings(NetworkProcessProxy& networkProcess)
{
    networkProcess.send(Messages::LegacyExtensionNetwork::SetProxyConfiguration(configuration()), 0);
}

void LegacyExtensionProxy::update()
{
    auto controller = controllingExtension();
    std::pair applied { controller, controller.isNull() ? emptyString() : makeString(setting(controller)->value->toJSONString(), '\n', setting(controller)->configuration) };
    if (m_applied == applied)
        return;
    bool changed = !!m_applied;
    m_applied = WTF::move(applied);
    auto current = configuration();
    CocoaCurlProxyConfiguration::setCurrent(current.isEmpty() ? nullptr : CocoaCurlProxyConfiguration::create(current));
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendSettings(networkProcess);
    if (changed && m_changeObserver)
        m_changeObserver();
}

} // namespace WebKit
