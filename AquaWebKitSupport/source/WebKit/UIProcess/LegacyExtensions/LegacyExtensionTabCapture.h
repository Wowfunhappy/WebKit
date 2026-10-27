// Firefox's tabs.captureTab for Safari 7 extensions: an image of an area of a tab's page, whether or not the
// tab is shown, as a PNG or JPEG data URL.

#pragma once

#include <WebCore/FloatRect.h>
#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class WebPageProxy;

namespace LegacyExtensions {

// extensionTypes.ImageDetails.
struct TabCaptureOptions {
    bool jpeg { false };
    // 0 to 100.
    std::optional<double> quality;
    // In CSS pixels of the document; the visible viewport when absent.
    std::optional<WebCore::FloatRect> rect;
    std::optional<double> scale;
};

// A tab showing another extension's page is captured blurred, as Firefox captures another add-on's page.
enum class BlurCapture : bool { No, Yes };

// Answers with the data URL, or with the error Firefox rejects the call with.
void captureTab(WebPageProxy&, const TabCaptureOptions&, BlurCapture, CompletionHandler<void(Expected<String, String>&&)>&&);

} // namespace LegacyExtensions

} // namespace WebKit
