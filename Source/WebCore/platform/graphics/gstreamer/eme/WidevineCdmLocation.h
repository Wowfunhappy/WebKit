// MAVERICKS_BACKPORT: where this process's Widevine CDM is. The module is Google's own, installed
// at runtime in the user's library by WidevineCdmInstaller, and named here by whichever port
// drives it: WebKitLegacy in its own process, and WebKit's UIProcess to each web process it grants
// a Widevine key system to. Kept apart from WidevineCdmModule.h so the naming reaches both ports
// without the Chromium CDM interface coming with it.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <wtf/text/WTFString.h>

namespace WebCore {

WEBCORE_EXPORT void setWidevineCdmModulePath(const String&);
WEBCORE_EXPORT const String& widevineCdmModulePath();

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
