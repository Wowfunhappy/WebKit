// The archive Google publishes the Widevine CDM in, read and checked. A CRX3
// is a protobuf header carrying signatures over an ordinary zip; the module is taken out of it
// only if the header proves the archive is what Google published under the extension id it is
// served from. WidevineCdmInstaller downloads it; MavericksSupport/tests/widevine-image drives
// this over a real archive, including one with a byte changed.

#pragma once

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <wtf/Expected.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

// The module's bytes, or a sentence naming what the archive is not.
Expected<Vector<uint8_t>, String> extractWidevineCdmModule(std::span<const uint8_t> archive);

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
