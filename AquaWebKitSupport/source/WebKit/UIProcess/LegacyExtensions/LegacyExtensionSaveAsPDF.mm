#import "config.h"
#import "LegacyExtensionSaveAsPDF.h"

#import "APIData.h"
#import "LegacyExtensionContentMessages.h"
#import "PageLoadState.h"
#import "PrintInfo.h"
#import "WebFrameProxy.h"
#import "WebPageProxy.h"
#import "WebPreferences.h"
#import "WebProcessProxy.h"
#import <AppKit/AppKit.h>
#import <algorithm>
#import <limits>
#import <unicode/uchar.h>
#import <wtf/BlockPtr.h>
#import <wtf/URL.h>
#import <wtf/WeakPtr.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/text/StringBuilder.h>

namespace WebKit::LegacyExtensions {

namespace {

// tabs.PageSettings as WebKit's printing takes them, in points.
struct PrintSettings {
    double paperWidth { 0 };
    double paperHeight { 0 };
    double marginTop { 0 };
    double marginRight { 0 };
    double marginBottom { 0 };
    double marginLeft { 0 };
    double scale { 1 };
    bool printsBackgrounds { false };
};

} // namespace

// Firefox's defaults: US Letter in inches, portrait, half-inch margins, shrinking to fit, no backgrounds.
// Margins are always inches. Shrinking to fit overrides the scaling, and WebKit's print layout shrinks a page
// that is wider than the paper either way. WebKit has one setting for background colors and images.
static PrintSettings printSettings(const JSON::Object& pageSettings)
{
    auto number = [&](ASCIILiteral name, double defaultValue) {
        return pageSettings.getDouble(name).value_or(defaultValue);
    };
    double unit = pageSettings.getInteger("paperSizeUnit"_s).value_or(0) == 1 ? 72 / 25.4 : 72;
    PrintSettings settings;
    settings.paperWidth = number("paperWidth"_s, 8.5) * unit;
    settings.paperHeight = number("paperHeight"_s, 11) * unit;
    if (pageSettings.getInteger("orientation"_s).value_or(0) == 1)
        std::swap(settings.paperWidth, settings.paperHeight);
    settings.marginTop = number("marginTop"_s, 0.5) * 72;
    settings.marginRight = number("marginRight"_s, 0.5) * 72;
    settings.marginBottom = number("marginBottom"_s, 0.5) * 72;
    settings.marginLeft = number("marginLeft"_s, 0.5) * 72;
    settings.scale = pageSettings.getBoolean("shrinkToFit"_s).value_or(true) ? 1 : number("scaling"_s, 1);
    settings.printsBackgrounds = pageSettings.getBoolean("showBackgroundColors"_s).value_or(false) || pageSettings.getBoolean("showBackgroundImages"_s).value_or(false);
    return settings;
}

// DownloadPaths.sanitize: runs of white space become one space, and the characters a file name cannot hold
// become underscores.
static String sanitizedFileName(StringView name)
{
    StringBuilder builder;
    bool pendingSpace = false;
    for (auto character : name.codePoints()) {
        if (u_isUWhiteSpace(character)) {
            pendingSpace = !builder.isEmpty();
            continue;
        }
        if (pendingSpace) {
            builder.append(' ');
            pendingSpace = false;
        }
        if (character < 0x20 || character == 0x7f || (character < 0x80 && strchr("\\/:*?\"<>|", static_cast<char>(character))))
            builder.append('_');
        else
            builder.append(character);
    }
    return builder.toString();
}

// ext-tabs.js: the page settings' file name, or else the page's title, or else the last segment of its
// URL's path, or else its host.
static String defaultFileName(WebPageProxy& page, const JSON::Object& pageSettings)
{
    auto name = pageSettings.getString("toFileName"_s);
    if (name.isEmpty())
        name = page.pageLoadState().title();
    if (name.isEmpty()) {
        URL url { page.pageLoadState().url() };
        String path = url.path().toString();
        if (NSString *decodedPath = [path.createNSString() stringByRemovingPercentEncoding])
            path = decodedPath;
        if (path.endsWith('/'))
            path = path.left(path.length() - 1);
        name = path.substring(path.reverseFind('/') + 1);
        if (name.isEmpty())
            name = url.host().toString();
    }
    return sanitizedFileName(name);
}

// The pages WebKit prints, as drawPagesToPDF draws them, each sized to the area of the paper inside the
// margins in the print layout's units, placed on the paper as the print view places a printed page: scaled
// to that area, at its top.
static RetainPtr<NSData> pdfOnPaper(std::span<const uint8_t> pages, const PrintSettings& settings)
{
    RetainPtr provider = adoptCF(CGDataProviderCreateWithCFData(bridge_cast(toNSData(pages).get())));
    RetainPtr document = provider ? adoptCF(CGPDFDocumentCreateWithProvider(provider.get())) : nullptr;
    size_t pageCount = document ? CGPDFDocumentGetNumberOfPages(document.get()) : 0;
    if (!pageCount)
        return nil;

    RetainPtr output = adoptNS([[NSMutableData alloc] init]);
    RetainPtr consumer = adoptCF(CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)output.get()));
    CGRect paper = CGRectMake(0, 0, settings.paperWidth, settings.paperHeight);
    RetainPtr context = adoptCF(CGPDFContextCreate(consumer.get(), &paper, nullptr));
    if (!context)
        return nil;
    CGRect printableArea = CGRectMake(settings.marginLeft, settings.marginBottom, settings.paperWidth - settings.marginLeft - settings.marginRight, settings.paperHeight - settings.marginTop - settings.marginBottom);
    for (size_t pageNumber = 1; pageNumber <= pageCount; ++pageNumber) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document.get(), pageNumber);
        CGRect pageBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        if (CGRectIsEmpty(pageBox))
            continue;
        CGFloat scale = std::min(printableArea.size.width / pageBox.size.width, printableArea.size.height / pageBox.size.height);
        CGContextBeginPage(context.get(), &paper);
        CGContextTranslateCTM(context.get(), printableArea.origin.x, CGRectGetMaxY(printableArea) - pageBox.size.height * scale);
        CGContextScaleCTM(context.get(), scale, scale);
        CGContextTranslateCTM(context.get(), -pageBox.origin.x, -pageBox.origin.y);
        CGContextDrawPDFPage(context.get(), page);
        CGContextEndPage(context.get());
    }
    CGPDFContextClose(context.get());
    return output;
}

// WebKit 2's printing of a page to PDF, as Safari's Export as PDF prints a page: beginPrinting lays out the
// main frame for paper of the settings' size and margins, drawPagesToPDF draws every page, and endPrinting
// returns the page to the screen. All three are sent at once, so the web content process runs the session
// through before any print Safari starts on the page meanwhile, and the page leaves printing mode before
// this returns. A page in a print session of Safari's is not printed, as Firefox fails a print of a page
// that is printing. Whether backgrounds print is the page's own setting for the session, set back from its
// preferences as it ends.
static void printToPDF(WebPageProxy& page, const PrintSettings& settings, CompletionHandler<void(RetainPtr<NSData>&&)>&& completionHandler)
{
    RefPtr frame = page.mainFrame();
    float availablePaperWidth = settings.paperWidth - settings.marginLeft - settings.marginRight;
    float availablePaperHeight = settings.paperHeight - settings.marginTop - settings.marginBottom;
    if (!frame || !page.hasRunningProcess() || page.isInPrintingMode() || !(availablePaperWidth > 0) || !(availablePaperHeight > 0) || !(settings.scale > 0))
        return completionHandler(nil);

    Ref process = frame->process();
    auto pageID = page.webPageIDInProcess(process);
    process->send(Messages::LegacyExtensionContent::SetPrintsBackgrounds(pageID, settings.printsBackgrounds), 0);
    PrintInfo printInfo { static_cast<float>(settings.scale), availablePaperWidth, availablePaperHeight, { static_cast<float>(settings.marginTop), static_cast<float>(settings.marginRight), static_cast<float>(settings.marginBottom), static_cast<float>(settings.marginLeft) } };
    page.beginPrinting(frame.get(), printInfo);
    page.drawPagesToPDF(*frame, printInfo, 0, std::numeric_limits<uint32_t>::max(), [settings, completionHandler = WTF::move(completionHandler)](API::Data* pages) mutable {
        completionHandler(pages ? pdfOnPaper(pages->span(), settings) : nil);
    });
    page.endPrinting();
    process->send(Messages::LegacyExtensionContent::SetPrintsBackgrounds(pageID, page.preferences().shouldPrintBackgrounds()), 0);
}

// ext-tabs.js's saveAsPDF: the user names the file in a save panel for PDF files, on the tab's window. A file
// the user chose to replace is "replaced", and a print or write that fails is "not_saved" or "not_replaced".
void saveTabAsPDF(WebPageProxy& page, const JSON::Object& pageSettings, CompletionHandler<void(String&&)>&& completionHandler)
{
    RetainPtr panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:@[ @"pdf" ]];
    [panel setNameFieldStringValue:defaultFileName(page, pageSettings).createNSString().get()];

    auto didChoose = [panel, weakPage = WeakPtr { page }, settings = printSettings(pageSettings), completionHandler = WTF::move(completionHandler)](NSInteger result) mutable {
        if (result != NSModalResponseOK)
            return completionHandler("canceled"_s);
        RetainPtr url = [panel URL];
        bool replacing = [[NSFileManager defaultManager] fileExistsAtPath:[url path]];
        RefPtr page = weakPage.get();
        if (!page || page->isClosed())
            return completionHandler(replacing ? "not_replaced"_s : "not_saved"_s);
        printToPDF(*page, settings, [url, replacing, completionHandler = WTF::move(completionHandler)](RetainPtr<NSData>&& pdf) mutable {
            bool written = pdf && [pdf writeToURL:url.get() options:NSDataWritingAtomic error:nil];
            completionHandler(written ? (replacing ? "replaced"_s : "saved"_s) : (replacing ? "not_replaced"_s : "not_saved"_s));
        });
    };

    NSWindow *window = page.platformWindow();
    if (window && !window.attachedSheet)
        [panel beginSheetModalForWindow:window completionHandler:makeBlockPtr(WTF::move(didChoose)).get()];
    else
        [panel beginWithCompletionHandler:makeBlockPtr(WTF::move(didChoose)).get()];
}

} // namespace WebKit::LegacyExtensions
