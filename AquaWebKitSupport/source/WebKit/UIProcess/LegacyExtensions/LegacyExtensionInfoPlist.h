// A Safari 7 extension's Info.plist, loaded from its safari-extension:// root through the protocol Safari serves
// its extensions' files with in this process.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>

namespace WebKit::LegacyExtensions {

// The website access of the extension whose files are at `root` (safari-extension://<key>/<token>/); none
// when its Info.plist cannot be read.
void loadWebsiteAccess(const URL& root, CompletionHandler<void(WebsiteAccess&&)>&&);

} // namespace WebKit::LegacyExtensions
