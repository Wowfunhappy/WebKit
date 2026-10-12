#include "config.h"
#include "LegacyExtensionPrivacy.h"

#include "LegacyExtensionInfoPlist.h"
#include "LegacyExtensionNetworkMessages.h"
#include "Logging.h"
#include "NetworkProcessProxy.h"
#include <wtf/FileSystem.h>
#include <wtf/NeverDestroyed.h>

namespace WebKit {

static constexpr auto networkPredictionEnabled = "network.networkPredictionEnabled"_s;
static constexpr auto hyperlinkAuditingEnabled = "websites.hyperlinkAuditingEnabled"_s;

LegacyExtensionPrivacy& LegacyExtensionPrivacy::singleton()
{
    static NeverDestroyed<LegacyExtensionPrivacy> privacy;
    return privacy;
}

bool LegacyExtensionPrivacy::isSetting(const String& name)
{
    return name == networkPredictionEnabled || name == hyperlinkAuditingEnabled;
}

static String settingsPath(const String& extensionKey)
{
    return FileSystem::pathByAppendingComponent(LegacyExtensions::storageDirectory(extensionKey), "PrivacySettings.json"_s);
}

HashMap<String, bool>& LegacyExtensionPrivacy::values(const String& extensionKey)
{
    return m_values.ensure(extensionKey, [&] {
        HashMap<String, bool> values;
        auto contents = FileSystem::readEntireFile(settingsPath(extensionKey));
        auto json = contents ? JSON::Value::parseJSON(String::fromUTF8(contents->span())) : nullptr;
        if (RefPtr object = json ? json->asObject() : nullptr) {
            for (auto& [name, value] : *object) {
                if (auto boolean = value->asBoolean(); boolean && isSetting(name))
                    values.set(name, *boolean);
            }
        }
        return values;
    }).iterator->value;
}

void LegacyExtensionPrivacy::save(const String& extensionKey)
{
    auto object = JSON::Object::create();
    for (auto& [name, value] : values(extensionKey))
        object->setBoolean(name, value);
    auto path = settingsPath(extensionKey);
    FileSystem::makeAllDirectories(FileSystem::parentPath(path));
    auto json = object->toJSONString().utf8();
    if (FileSystem::overwriteEntireFile(path, byteCast<uint8_t>(json.span())) != json.length())
        RELEASE_LOG_ERROR(Extensions, "Unable to save the privacy settings of extension %" PUBLIC_LOG_STRING, extensionKey.utf8().data());
}

void LegacyExtensionPrivacy::extensionDidLoad(const String& extensionKey)
{
    m_loadedExtensions.removeAll(extensionKey);
    m_loadedExtensions.append(extensionKey);
    update();
}

void LegacyExtensionPrivacy::extensionDidUnload(const String& extensionKey)
{
    if (m_loadedExtensions.removeAll(extensionKey))
        update();
}

String LegacyExtensionPrivacy::controllingExtension(const String& name)
{
    for (size_t index = m_loadedExtensions.size(); index; --index) {
        auto extensionKey = m_loadedExtensions[index - 1];
        if (values(extensionKey).contains(name))
            return extensionKey;
    }
    return { };
}

bool LegacyExtensionPrivacy::value(const String& name)
{
    auto extensionKey = controllingExtension(name);
    return extensionKey.isNull() || values(extensionKey).get(name);
}

Ref<JSON::Object> LegacyExtensionPrivacy::details(const String& extensionKey, const String& name)
{
    auto controller = controllingExtension(name);
    auto details = JSON::Object::create();
    details->setBoolean("value"_s, value(name));
    if (controller.isNull())
        details->setString("levelOfControl"_s, "controllable_by_this_extension"_s);
    else if (controller == extensionKey)
        details->setString("levelOfControl"_s, "controlled_by_this_extension"_s);
    else
        details->setString("levelOfControl"_s, "controlled_by_other_extensions"_s);
    return details;
}

void LegacyExtensionPrivacy::set(const String& extensionKey, const String& name, bool newValue)
{
    values(extensionKey).set(name, newValue);
    save(extensionKey);
    update();
}

void LegacyExtensionPrivacy::clear(const String& extensionKey, const String& name)
{
    if (!values(extensionKey).remove(name))
        return;
    save(extensionKey);
    update();
}

void LegacyExtensionPrivacy::sendSettings(NetworkProcessProxy& networkProcess)
{
    networkProcess.send(Messages::LegacyExtensionNetwork::SetPrivacySettings(value(networkPredictionEnabled), value(hyperlinkAuditingEnabled)), 0);
}

void LegacyExtensionPrivacy::update()
{
    bool applies = false;
    Vector<String> changed;
    for (auto name : { networkPredictionEnabled, hyperlinkAuditingEnabled }) {
        std::pair applied { value(name), controllingExtension(name) };
        auto iterator = m_applied.find(name);
        if (iterator != m_applied.end() && iterator->value == applied)
            continue;
        applies = true;
        if (iterator != m_applied.end())
            changed.append(name);
        m_applied.set(name, WTF::move(applied));
    }
    if (!applies)
        return;
    for (Ref networkProcess : NetworkProcessProxy::allNetworkProcesses())
        sendSettings(networkProcess);
    if (m_changeObserver) {
        for (auto& name : changed)
            m_changeObserver(name);
    }
}

} // namespace WebKit
