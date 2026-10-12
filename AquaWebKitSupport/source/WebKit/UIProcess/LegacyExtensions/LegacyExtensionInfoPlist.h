// A Safari 7 extension's Info.plist, loaded from its safari-extension:// root through the protocol Safari serves
// its extensions' files with in this process.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>
#include <wtf/JSONValues.h>

namespace WebKit::LegacyExtensions {

struct InfoPlist {
    WebsiteAccess websiteAccess;
    // The `declarative_net_request` entry, with a WebExtension manifest's keys (`rule_resources`, each with
    // `id`, `enabled` and `path`).
    RefPtr<JSON::Object> declarativeNetRequest;
    // The `mime_types_handler` entry, with a WebExtension manifest's keys: each MIME type's `handler_url` and
    // `can_embed`.
    RefPtr<JSON::Object> mimeTypesHandler;
};

// The Info.plist of the extension whose files are at `root` (safari-extension://<key>/<token>/); empty when it
// cannot be read.
void loadInfoPlist(const URL& root, CompletionHandler<void(InfoPlist&&)>&&);

// The directory an extension's persistent state is in, where WebKit keeps a WebExtension's.
String storageDirectory(const String& extensionKey);

} // namespace WebKit::LegacyExtensions
