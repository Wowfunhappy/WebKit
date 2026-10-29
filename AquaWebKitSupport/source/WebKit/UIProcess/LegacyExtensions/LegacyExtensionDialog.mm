#import "config.h"
#import "LegacyExtensionDialog.h"

#import "LegacyExtensionHost.h"
#import "LegacyExtensionInput.h"
#import "WebPageProxy.h"
#import <AppKit/AppKit.h>
#import <wtf/RunLoop.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyExtensionDialog);

// The innermost synchronous dialog callback; each links to the one it is nested in.
static LegacyExtensionDialog* currentDialog;

struct LegacyExtensionDialog::Platform {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(Platform);
public:
    RetainPtr<NSWindow> previousModalWindow;
    RetainPtr<NSWindow> window;
    RetainPtr<NSButton> acceptButton;
    RetainPtr<NSButton> dismissButton;
    RetainPtr<NSTextField> textField;
};

std::unique_ptr<LegacyExtensionDialog> LegacyExtensionDialog::createForSynchronousCallback(WebPageProxy& page, Type type, bool isSynchronous, const String& message, const String& defaultText)
{
    if (!isSynchronous || !WTF::MacApplication::isSafari())
        return nullptr;
    return makeUnique<LegacyExtensionDialog>(page, type, message, defaultText);
}

LegacyExtensionDialog::LegacyExtensionDialog(WebPageProxy& page, Type type, const String& message, const String& defaultText)
    : m_page(page)
    , m_type(type)
    , m_message(message)
    , m_defaultText(defaultText)
    , m_previous(currentDialog)
    , m_platform(makeUnique<Platform>())
{
    currentDialog = this;
    m_platform->previousModalWindow = NSApp.modalWindow;
    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }] {
        if (weakThis)
            weakThis->findPanel();
    });
}

LegacyExtensionDialog::~LegacyExtensionDialog()
{
    ASSERT(currentDialog == this);
    currentDialog = m_previous;
}

// The modal window the callback opened. Its default button accepts; the dismissing button is the other visible
// button sending an action to the same target: NSAlert's in NSRunAlertPanel and NSAlert panels, the panel
// controller's in Safari's own panels.
void LegacyExtensionDialog::findPanel()
{
    NSWindow *window = NSApp.modalWindow;
    if (!window || window == m_platform->previousModalWindow.get())
        return;
    m_platform->window = window;
    RetainPtr acceptButton = dynamic_objc_cast<NSButton>(window.defaultButtonCell.controlView);
    m_platform->acceptButton = acceptButton;
    auto visit = [&](auto&& visit, NSView *view) -> void {
        if (auto *button = dynamic_objc_cast<NSButton>(view); button && button != acceptButton.get() && !button.isHiddenOrHasHiddenAncestor && button.action && button.target == acceptButton.get().target)
            m_platform->dismissButton = button;
        if (auto *field = dynamic_objc_cast<NSTextField>(view); field.isEditable)
            m_platform->textField = field;
        for (NSView *child in view.subviews)
            visit(visit, child);
    };
    visit(visit, window.contentView);

    if (!m_page->hasRunningProcess())
        return;
    auto details = JSON::Object::create();
    static constexpr ASCIILiteral types[] = { "alert"_s, "confirm"_s, "prompt"_s, "beforeunload"_s };
    details->setString("type"_s, types[static_cast<unsigned>(m_type)]);
    details->setString("message"_s, m_message);
    if (m_type == Type::Prompt)
        details->setString("defaultText"_s, m_defaultText);
    LegacyExtensionHost::singleton().dispatchDialogOpened(*this, WTF::move(details));
}

bool LegacyExtensionDialog::isOpen() const
{
    return !m_answered && m_platform->window && m_platform->window.get().isVisible;
}

Expected<void, String> LegacyExtensionDialog::pressButton(bool accept, const String& text)
{
    // Stopping a modal session stops the innermost one, so a dialog under another modal window waits for it.
    if (m_platform->window.get() != NSApp.modalWindow)
        return makeUnexpected("The tab's dialog is blocked by another modal window."_s);
    RetainPtr button = accept || m_type == Type::Alert ? m_platform->acceptButton : m_platform->dismissButton;
    if (accept && m_type == Type::Prompt && !text.isNull())
        [m_platform->textField setStringValue:text.createNSString().get()];
    // Several answers can arrive before the modal loop ends.
    m_answered = true;
    [button performClick:nil];
    return { };
}

Expected<void, String> LegacyExtensionDialog::answer(WebPageProxy& page, const String& extensionKey, const LegacyExtensions::WebsiteAccess& access, const JSON::Object& answer)
{
    if (auto result = LegacyExtensions::checkInputAccess(page, extensionKey, access); !result)
        return result;
    auto accept = answer.getBoolean("accept"_s);
    if (!accept)
        return makeUnexpected("A dialog answer requires a boolean accept."_s);
    auto text = answer.getString("text"_s);
    if (answer.getValue("text"_s) && text.isNull())
        return makeUnexpected("Prompt text is a string."_s);
    // The innermost of the page's callbacks holds its open dialog.
    for (auto* dialog = currentDialog; dialog; dialog = dialog->m_previous) {
        if (&dialog->page() != &page)
            continue;
        if (!dialog->isOpen())
            break;
        return dialog->pressButton(*accept, text);
    }
    return makeUnexpected("The tab has no open JavaScript dialog."_s);
}

} // namespace WebKit
