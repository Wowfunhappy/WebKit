#pragma once

#include <wtf/Expected.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

// The caller authenticates the complete MAR against Mozilla's HTTPS release checksum.
Expected<void, String> extractWidevineFirefoxFiles(std::span<const uint8_t>, const String& directory);

} // namespace WebCore
