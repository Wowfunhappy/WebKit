#pragma once

#include <optional>
#include <wtf/Forward.h>

namespace WTF {

class URL;
class URLTextEncoding;

// Safari 7 serves a legacy extension's files at safari-extension://<key>/<token>/<path>, <token> fixed
// for the launch. That directory is the root an extension document's root-relative references resolve
// against, as a WebExtension's resolve against its origin: "/js/a.js" from
// safari-extension://<key>/<token>/page.html is safari-extension://<key>/<token>/js/a.js.
std::optional<URL> resolveLegacyExtensionRootRelativeURL(const URL& base, const String& relative, const URLTextEncoding*);

} // namespace WTF
