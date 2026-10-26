#pragma once

#include <optional>
#include <wtf/URL.h>

namespace WTF {

// Safari 7 serves a legacy extension's files at safari-extension://<key>/<token>/<path>, <token> fixed
// for the launch. That directory is the root an extension document's relative references resolve
// within, as a WebExtension's resolve within its origin: "/js/a.js" and "../js/a.js" from
// safari-extension://<key>/<token>/page.html are both safari-extension://<key>/<token>/js/a.js.
struct LegacyExtensionRoot {
    // The base with its path taken below the root, and the reference resolved against it.
    URL base;
    String reference;
    // "/<token>", which goes back in front of the resolved path.
    String path;
};

std::optional<LegacyExtensionRoot> legacyExtensionRootForReference(const URL& base, const String& relative);
void placeUnderLegacyExtensionRoot(URL&, const LegacyExtensionRoot&);

} // namespace WTF
