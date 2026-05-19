// 10.9 backport: Minimal RenderThemeMac.
// We define the full set of `final` virtual functions declared in the header
// so the vtable gets emitted in __DATA,__const (instead of being a 3-byte
// text stub from libpolyfill.a's webcore_stubs.o that GP-faults on any
// vcall). All implementations are trivial stubs — for a data: URL test page
// we never actually render form controls, so empty/zero defaults are safe.
#include "config.h"
#include "RenderThemeMac.h"

#import "Color.h"
#import "FontCascade.h"
#import "FontCascadeDescription.h"
#import "GraphicsContext.h"
#import "Page.h"
#import "PaintInfo.h"
#import "RenderBox.h"
#import "RenderProgress.h"
#import "RenderStyle.h"
#import "Settings.h"
#import "StylePadding.h"
#import "StylePrimitiveNumeric.h"
#import <wtf/NeverDestroyed.h>

namespace WebCore {

RenderThemeMac::RenderThemeMac() = default;

RenderThemeMac& RenderTheme::singleton()
{
    static NeverDestroyed<RenderThemeMac> theme;
    return theme;
}

bool RenderThemeMac::controlSupportsTints(const RenderElement&) const { return false; }
void RenderThemeMac::inflateRectForControlRenderer(const RenderElement&, FloatRect&) { }
bool RenderThemeMac::isControlStyled(const RenderStyle&) const { return false; }
bool RenderThemeMac::supportsSelectionForegroundColors(OptionSet<StyleColorOptions>) const { return false; }

// 10.9 backport: upstream RenderThemeMac reads NSColor.selectedTextBackgroundColor etc.,
// which routes through AppKit / NSColor SPI that crashes via stubbed paths on 10.9.
// Hard-code the OS X 10.9 default colors so selection/focus actually renders visibly.
//   Active selection background:   sRGB(0.65, 0.81, 0.99)  ~ macOS standard blue
//   Inactive selection background: sRGB(0.84, 0.84, 0.84)  ~ light gray
//   Active focus ring:             sRGB(0.39, 0.59, 0.94)  ~ keyboard focus
//   Active selection foreground:   sRGB(0, 0, 0)           ~ black (default)
//   Search highlight:              sRGB(1.0, 0.93, 0.4)    ~ yellow
Color RenderThemeMac::platformActiveSelectionBackgroundColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 166, 207, 252, 255 }; }
Color RenderThemeMac::platformActiveSelectionForegroundColor(OptionSet<StyleColorOptions>) const { return Color::black; }
Color RenderThemeMac::transformSelectionBackgroundColor(const Color& c, OptionSet<StyleColorOptions>) const { return c; }
Color RenderThemeMac::platformInactiveSelectionBackgroundColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 220, 220, 220, 255 }; }
Color RenderThemeMac::platformInactiveSelectionForegroundColor(OptionSet<StyleColorOptions>) const { return Color::black; }
Color RenderThemeMac::platformActiveListBoxSelectionBackgroundColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 56, 117, 215, 255 }; }
Color RenderThemeMac::platformActiveListBoxSelectionForegroundColor(OptionSet<StyleColorOptions>) const { return Color::white; }
Color RenderThemeMac::platformInactiveListBoxSelectionBackgroundColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 220, 220, 220, 255 }; }
Color RenderThemeMac::platformInactiveListBoxSelectionForegroundColor(OptionSet<StyleColorOptions>) const { return Color::black; }
Color RenderThemeMac::platformFocusRingColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 100, 150, 240, 255 }; }
Color RenderThemeMac::platformTextSearchHighlightColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 255, 237, 102, 255 }; }
Color RenderThemeMac::platformAnnotationHighlightBackgroundColor(OptionSet<StyleColorOptions>) const { return SRGBA<uint8_t> { 255, 237, 102, 255 }; }
Color RenderThemeMac::platformDefaultButtonTextColor(OptionSet<StyleColorOptions>) const { return Color(); }
Color RenderThemeMac::platformAutocorrectionReplacementMarkerColor(OptionSet<StyleColorOptions>) const { return Color(); }

int RenderThemeMac::minimumMenuListSize(const RenderStyle&) const { return 0; }
void RenderThemeMac::adjustSliderThumbSize(RenderStyle&, const Element*) const { }
IntSize RenderThemeMac::sliderTickSize() const { return IntSize(); }
int RenderThemeMac::sliderTickOffsetFromTrackCenter() const { return 0; }

Style::PaddingBox RenderThemeMac::popupInternalPaddingBox(const RenderStyle&) const { return Style::PaddingBox { 0_css_px }; }
PopupMenuStyle::Size RenderThemeMac::popupMenuSize(const RenderStyle&, IntRect&) const { return PopupMenuStyle::Size::Normal; }

std::optional<FontCascadeDescription> RenderThemeMac::controlFont(StyleAppearance, const FontCascade&, float) const { return std::nullopt; }
Style::PaddingBox RenderThemeMac::controlPadding(StyleAppearance, const Style::PaddingBox& p, float) const { return p; }
Style::PreferredSizePair RenderThemeMac::controlSize(StyleAppearance, const FontCascade&, const Style::PreferredSizePair& s, float) const { return s; }
Style::MinimumSizePair RenderThemeMac::minimumControlSize(StyleAppearance, const FontCascade&, const Style::MinimumSizePair& s, float) const { return s; }
Style::LineWidthBox RenderThemeMac::controlBorder(StyleAppearance, const FontCascade&, const Style::LineWidthBox& b, float, const Element*) const { return b; }
bool RenderThemeMac::controlRequiresPreWhiteSpace(StyleAppearance) const { return false; }

FloatSize RenderThemeMac::meterSizeForBounds(const RenderMeter&, const FloatRect& r) const { return r.size(); }
bool RenderThemeMac::supportsMeter(StyleAppearance) const { return false; }

void RenderThemeMac::createColorWellSwatchSubtree(HTMLElement&) { }
void RenderThemeMac::setColorWellSwatchBackground(HTMLElement&, Color) { }

IntRect RenderThemeMac::progressBarRectForBounds(const RenderProgress&, const IntRect& r) const { return r; }

Color RenderThemeMac::systemColor(CSSValueID cssValueId, OptionSet<StyleColorOptions> options) const
{
    // 10.9 backport: the upstream RenderThemeMac::systemColor depends on AppKit
    // semantic colors (-apple-system-*) that aren't available here. Fall through
    // to the base RenderTheme implementation, which provides spec defaults like
    // Color::black for CanvasText and Color::white for Canvas. Without this,
    // the UA stylesheet `body { color: CanvasText }` would resolve to an invalid
    // Color and all default-styled text would be unpaintable.
    return RenderTheme::systemColor(cssValueId, options);
}

bool RenderThemeMac::canPaint(const PaintInfo&, const Settings&, StyleAppearance) const { return false; }
bool RenderThemeMac::canCreateControlPartForRenderer(const RenderElement&) const { return false; }
bool RenderThemeMac::canCreateControlPartForBorderOnly(const RenderElement&) const { return false; }
bool RenderThemeMac::canCreateControlPartForDecorations(const RenderElement&) const { return false; }

int RenderThemeMac::baselinePosition(const RenderBox& box) const { return RenderTheme::baselinePosition(box); }

bool RenderThemeMac::supportsLargeFormControls() const { return false; }

void RenderThemeMac::adjustMenuListStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustMenuListButtonStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSliderTrackStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSliderThumbStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSearchFieldStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSearchFieldCancelButtonStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSearchFieldDecorationPartStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSearchFieldResultsDecorationPartStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustSearchFieldResultsButtonStyle(RenderStyle&, const Element*) const { }
void RenderThemeMac::adjustListButtonStyle(RenderStyle&, const Element*) const { }

#if ENABLE(SERVICE_CONTROLS)
void RenderThemeMac::adjustImageControlsButtonStyle(RenderStyle&, const Element*) const { }
IntSize RenderThemeMac::imageControlsButtonSize() const { return IntSize(); }
bool RenderThemeMac::isImageControlsButton(const Element&) const { return false; }
#endif

#if ENABLE(ATTACHMENT_ELEMENT)
LayoutSize RenderThemeMac::attachmentIntrinsicSize(const RenderAttachment&) const { return LayoutSize(); }
bool RenderThemeMac::paintAttachment(const RenderElement&, const PaintInfo&, const IntRect&) { return false; }
#endif

String RenderThemeMac::fileListNameForWidth(const FileList*, const FontCascade&, int, bool) const { return String(); }

bool RenderThemeMac::searchFieldShouldAppearAsTextField(const RenderStyle&, const Settings&) const { return true; }

bool RenderThemeMac::usesTestModeFocusRingColor() const { return false; }

} // namespace WebCore
