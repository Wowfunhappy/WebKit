#import "config.h"
#import "LegacyExtensionClipboard.h"

#import <AppKit/NSPasteboard.h>
#import <WebCore/PasteboardItemInfo.h>
#import <WebCore/PlatformPasteboard.h>

namespace WebKit::LegacyExtensions {

static constexpr auto textPlainType = "text/plain"_s;

// PlatformPasteboard::informationForItemAtIndex gives an item text/plain exactly when the item has
// NSPasteboardTypeString and no file URL, and PasteboardPlainText reads that type first.
std::optional<String> readClipboardText()
{
    WebCore::PlatformPasteboard pasteboard(NSPasteboardNameGeneral);
    auto changeCountAtStart = pasteboard.changeCount();
    auto allInfo = pasteboard.allPasteboardItemInfo(changeCountAtStart);
    if (!allInfo)
        return std::nullopt;

    String text;
    for (size_t index = 0; index < allInfo->size(); ++index) {
        if (allInfo->at(index).webSafeTypesByFidelity.contains(textPlainType)) {
            text = pasteboard.readString(index, NSPasteboardTypeString);
            break;
        }
    }

    if (changeCountAtStart != pasteboard.changeCount())
        return std::nullopt;
    return text;
}

} // namespace WebKit::LegacyExtensions
