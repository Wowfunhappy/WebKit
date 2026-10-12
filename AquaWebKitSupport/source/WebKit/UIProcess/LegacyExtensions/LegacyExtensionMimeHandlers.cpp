#include "config.h"
#include "LegacyExtensionMimeHandlers.h"

#include "LegacyExtensionContentMessages.h"
#include "Logging.h"
#include "LegacyExtensionInfoPlist.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include <wtf/FileSystem.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>

namespace WebKit {

// The one type Chrome lets an extension handle.
static constexpr auto handledMIMEType = "application/pdf"_s;

LegacyExtensionMimeHandlers& LegacyExtensionMimeHandlers::singleton()
{
    static NeverDestroyed<LegacyExtensionMimeHandlers> handlers;
    return handlers;
}

static String optionsPath(const String& extensionKey)
{
    return FileSystem::pathByAppendingComponent(LegacyExtensions::storageDirectory(extensionKey), "MimeHandlerOptions.json"_s);
}

HashMap<String, bool, ASCIICaseInsensitiveHash>& LegacyExtensionMimeHandlers::disabledTypes(const String& extensionKey)
{
    return m_disabledTypes.ensure(extensionKey, [&] {
        HashMap<String, bool, ASCIICaseInsensitiveHash> disabledTypes;
        auto contents = FileSystem::readEntireFile(optionsPath(extensionKey));
        auto value = contents ? JSON::Value::parseJSON(String::fromUTF8(contents->span())) : nullptr;
        if (RefPtr options = value ? value->asObject() : nullptr) {
            for (auto& [mimeType, typeOptions] : *options) {
                RefPtr object = typeOptions->asObject();
                if (object && !object->getBoolean("enabled"_s).value_or(true))
                    disabledTypes.set(mimeType, true);
            }
        }
        return disabledTypes;
    }).iterator->value;
}

void LegacyExtensionMimeHandlers::extensionDidLoad(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& mimeTypesHandler)
{
    m_extensions.removeAllMatching([&](auto& extension) {
        return extension.extensionKey == extensionKey;
    });
    Extension extension { extensionKey, { } };
    if (mimeTypesHandler) {
        for (auto& [mimeType, value] : *mimeTypesHandler) {
            RefPtr entry = value->asObject();
            if (!entry)
                continue;
            if (!equalIgnoringASCIICase(mimeType, handledMIMEType)) {
                RELEASE_LOG_ERROR(Extensions, "Extension %" PUBLIC_LOG_STRING " cannot handle MIME type %" PUBLIC_LOG_STRING, extensionKey.utf8().data(), mimeType.utf8().data());
                continue;
            }
            // The handler is a page of the extension.
            URL handlerURL { root, entry->getString("handler_url"_s) };
            if (!handlerURL.isValid() || handlerURL.protocol() != root.protocol() || handlerURL.host() != root.host() || !handlerURL.path().startsWith(root.path()))
                continue;
            extension.handlers.append({ mimeType.convertToASCIILowercase(), WTF::move(handlerURL), entry->getBoolean("can_embed"_s).value_or(false) });
        }
    }
    if (extension.handlers.isEmpty())
        return update();
    m_extensions.append(WTF::move(extension));
    update();
}

void LegacyExtensionMimeHandlers::extensionDidUnload(const String& extensionKey)
{
    if (m_extensions.removeAllMatching([&](auto& extension) { return extension.extensionKey == extensionKey; }))
        update();
}

Ref<JSON::Object> LegacyExtensionMimeHandlers::options(const String& extensionKey, const String& mimeType)
{
    auto options = JSON::Object::create();
    options->setBoolean("enabled"_s, !disabledTypes(extensionKey).contains(mimeType));
    return options;
}

void LegacyExtensionMimeHandlers::setOptions(const String& extensionKey, const String& mimeType, bool enabled)
{
    auto& disabled = disabledTypes(extensionKey);
    if (enabled)
        disabled.remove(mimeType);
    else
        disabled.set(mimeType, true);

    auto options = JSON::Object::create();
    for (auto& type : disabled.keys()) {
        auto typeOptions = JSON::Object::create();
        typeOptions->setBoolean("enabled"_s, false);
        options->setObject(type, WTF::move(typeOptions));
    }
    auto path = optionsPath(extensionKey);
    FileSystem::makeAllDirectories(FileSystem::parentPath(path));
    auto json = options->toJSONString().utf8();
    if (FileSystem::overwriteEntireFile(path, byteCast<uint8_t>(json.span())) != json.length())
        RELEASE_LOG_ERROR(Extensions, "Unable to save the mimeHandler options of extension %" PUBLIC_LOG_STRING, extensionKey.utf8().data());
    update();
}

void LegacyExtensionMimeHandlers::update()
{
    HashMap<String, Ref<JSON::Object>> handlers;
    for (auto& extension : m_extensions) {
        auto& disabled = disabledTypes(extension.extensionKey);
        for (auto& handler : extension.handlers) {
            if (disabled.contains(handler.mimeType))
                continue;
            auto description = JSON::Object::create();
            description->setString("mimeType"_s, handler.mimeType);
            description->setString("extensionKey"_s, extension.extensionKey);
            description->setString("handlerURL"_s, handler.handlerURL.string());
            description->setBoolean("canEmbed"_s, handler.canEmbed);
            handlers.set(handler.mimeType, WTF::move(description));
        }
    }
    auto array = JSON::Array::create();
    for (auto& handler : handlers.values())
        array->pushObject(handler.copyRef());
    auto json = array->toJSONString();
    if (json == m_handlersJSON)
        return;
    m_handlersJSON = WTF::move(json);
    for (Ref pool : WebProcessPool::allProcessPools())
        pool->sendToAllProcesses(Messages::LegacyExtensionContent::SetMimeHandlers(m_handlersJSON));
}

void LegacyExtensionMimeHandlers::sendHandlers(WebProcessProxy& process)
{
    process.send(Messages::LegacyExtensionContent::SetMimeHandlers(m_handlersJSON), 0);
}

} // namespace WebKit
