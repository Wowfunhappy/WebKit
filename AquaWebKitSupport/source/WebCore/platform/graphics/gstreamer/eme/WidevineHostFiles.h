#pragma once

#include <array>
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {

inline constexpr auto widevineOriginalName = "libwidevinecdm.original.dylib"_s;
inline constexpr auto widevineSignatureName = "libwidevinecdm.dylib.sig"_s;
inline constexpr auto firefoxApplicationInfo = "Contents/Resources/application.ini"_s;
inline constexpr auto firefoxLicense = "Contents/Resources/license.html"_s;

struct WidevineHostFileNames {
    ASCIILiteral image;
    ASCIILiteral signature;
};

inline constexpr std::array firefoxHostFiles {
    WidevineHostFileNames { "Contents/MacOS/media-plugin-helper.app/Contents/MacOS/Firefox Media Plugin Helper"_s,
        "Contents/MacOS/media-plugin-helper.app/Contents/Resources/Firefox Media Plugin Helper.sig"_s },
    WidevineHostFileNames { "Contents/MacOS/firefox"_s, "Contents/Resources/firefox.sig"_s },
    WidevineHostFileNames { "Contents/MacOS/XUL"_s, "Contents/Resources/XUL.sig"_s }
};

} // namespace WebCore
