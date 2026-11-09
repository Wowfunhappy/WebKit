// A Safari 7 extension's Info.plist, loaded from its safari-extension:// root through the protocol Safari serves
// its extensions' files with in this process.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>
#include <wtf/JSONValues.h>

namespace WebKit::LegacyExtensions {

struct InfoPlist {
    WebsiteAccess websiteAccess;
    bool hasGlobalPage { false };
    // The `declarative_net_request` entry, with a WebExtension manifest's keys (`rule_resources`, each with
    // `id`, `enabled` and `path`).
    RefPtr<JSON::Object> declarativeNetRequest;
    // The `mime_types_handler` entry, with a WebExtension manifest's keys: each MIME type's `handler_url` and
    // `can_embed`.
    RefPtr<JSON::Object> mimeTypesHandler;
    // `WebExtensionDevtoolsPage`, a WebExtension manifest's `devtools_page`: the path of the extension's devtools
    // page within it.
    String devToolsPage;
    // The files web pages can use whatever the extension does (`web_accessible_resources`) and cannot use whatever
    // it does (`web_inaccessible_resources`), as path patterns within the extension. See
    // WebCore::LegacyExtensionResourceAccess.
    Vector<String> webAccessibleResources;
    Vector<String> webInaccessibleResources;
    // CFBundleVersion and CFBundleShortVersionString, and the SHA-1 of the Info.plist, as
    // "<version>/<short version>/<hash>": another version of the extension, or another bundle, has another.
    String version;
};

// The Info.plist of the extension whose files are at `root` (safari-extension://<key>/<token>/); empty when it
// cannot be read.
void loadInfoPlist(const URL& root, CompletionHandler<void(InfoPlist&&)>&&);
// The text of the file at `path` within the extension whose files are at `root`, as UTF-8; null when it cannot be read.
void loadExtensionFile(const URL& root, const String& path, CompletionHandler<void(String&&)>&&);

// The directory an extension's persistent state is in, where WebKit keeps a WebExtension's.
String storageDirectory(const String& extensionKey);

} // namespace WebKit::LegacyExtensions
