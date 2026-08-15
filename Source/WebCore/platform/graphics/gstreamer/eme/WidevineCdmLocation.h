// MAVERICKS_BACKPORT: where this process's Widevine CDM is. The module is Google's own, installed
// at runtime in the user's library by the UIProcess (WebKit's WidevineCdmInstaller), which names
// it to each web process it grants a Widevine key system to. Kept apart from WidevineCdmModule.h
// so the naming reaches WebKit without the Chromium CDM interface coming with it.

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <wtf/text/WTFString.h>

namespace WebCore {

WEBCORE_EXPORT void setWidevineCdmModulePath(const String&);
WEBCORE_EXPORT const String& widevineCdmModulePath();

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
