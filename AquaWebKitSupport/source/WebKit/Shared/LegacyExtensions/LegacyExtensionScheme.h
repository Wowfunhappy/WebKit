// The safari-extension scheme Safari 7 serves its legacy extensions' files from, as every process that
// loads or checks them must treat it.

#pragma once

namespace WebKit::LegacyExtensions {

// Registers the scheme in this process: secure; handled by a scheme handler, which gives its documents
// a tuple origin as a WebExtension's own scheme has; and exempt from a page's Content Security Policy, so
// a content script's extension scripts, frames and images load into any page. Safari 7 registers it as
// a custom protocol, as secure and as domain-relaxation-forbidden through WKContext, which has no CSP
// exemption for it to call.
void registerExtensionScheme();

} // namespace WebKit::LegacyExtensions
