// MAVERICKS_BACKPORT: Google builds the Widevine CDM against a newer macOS than this one, so the
// module WidevineCdmInstaller downloads is retargeted at what 10.9 actually provides before it is
// installed. See WidevineCdmImage.cpp for what each pass does.

#pragma once

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <wtf/Expected.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

// Rewrites |image| in place. |gapLibraryPath| is the load path of the library carrying the entry
// points this host lacks, as the module will reference it (an @loader_path-relative path, so the
// library is found beside the installed module). The error is a sentence naming what stopped it.
Expected<void, String> prepareWidevineCdmImage(Vector<uint8_t>& image, const String& gapLibraryPath, const String& gapLibraryFilePath);

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
