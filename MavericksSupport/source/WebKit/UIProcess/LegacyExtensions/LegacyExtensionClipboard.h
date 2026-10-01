// The general pasteboard as navigator.clipboard.readText() reads it, for Safari 7 extension pages the
// UI-process router answers.

#pragma once

#include <optional>
#include <wtf/Forward.h>

namespace WebKit::LegacyExtensions {

// Clipboard::readText's read: the plain text of the first item that has any, or nullopt when the
// pasteboard changes while it is read.
std::optional<String> readClipboardText();

} // namespace WebKit::LegacyExtensions
