// The general pasteboard as navigator.clipboard's text methods use it, for Safari 7 extension pages the
// UI-process router answers.

#pragma once

#include <optional>
#include <wtf/Forward.h>

namespace WebCore {
enum class PasteboardDataLifetime : bool;
}

namespace WebKit::LegacyExtensions {

// Clipboard::writeText's write, on behalf of a document with the given pasteboard origin identifier.
void writeClipboardText(const String&, const String& originIdentifier, WebCore::PasteboardDataLifetime);

// Clipboard::readText's read: the plain text of the first item that has any, or nullopt when the
// pasteboard changes while it is read.
std::optional<String> readClipboardText();

} // namespace WebKit::LegacyExtensions
