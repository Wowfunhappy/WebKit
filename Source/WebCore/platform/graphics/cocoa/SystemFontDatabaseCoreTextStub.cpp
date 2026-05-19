// Minimal stub for SystemFontDatabaseCoreText. The real implementation
// uses CT 10.10-10.13+ APIs we don't have. This stub returns empty values
// for all methods so the font subsystem doesn't crash, just renders no text.
#include "config.h"
#include "SystemFontDatabaseCoreText.h"
#include <wtf/NeverDestroyed.h>

namespace WebCore {

SystemFontDatabaseCoreText::SystemFontDatabaseCoreText() = default;

SystemFontDatabaseCoreText& SystemFontDatabaseCoreText::forCurrentThread()
{
    static NeverDestroyed<SystemFontDatabaseCoreText> instance;
    return instance.get();
}

std::optional<SystemFontKind> SystemFontDatabaseCoreText::matchSystemFontUse(const AtomString&)
{
    return std::nullopt;
}

Vector<RetainPtr<CTFontDescriptorRef>> SystemFontDatabaseCoreText::cascadeList(const FontDescription&, const AtomString&, SystemFontKind, AllowUserInstalledFonts)
{
    return { };
}

Vector<RetainPtr<CTFontDescriptorRef>> SystemFontDatabaseCoreText::cascadeList(const CascadeListParameters&, SystemFontKind)
{
    return { };
}

String SystemFontDatabaseCoreText::serifFamily(const String&) { return "Times"_s; }
String SystemFontDatabaseCoreText::sansSerifFamily(const String&) { return "Helvetica"_s; }
String SystemFontDatabaseCoreText::cursiveFamily(const String&) { return "Apple Chancery"_s; }
String SystemFontDatabaseCoreText::fantasyFamily(const String&) { return "Papyrus"_s; }
String SystemFontDatabaseCoreText::monospaceFamily(const String&) { return "Menlo"_s; }

const AtomString& SystemFontDatabaseCoreText::systemFontShorthandFamily(FontShorthand)
{
    static NeverDestroyed<AtomString> name { "Helvetica"_s };
    return name.get();
}

float SystemFontDatabaseCoreText::systemFontShorthandSize(FontShorthand) { return 13.0f; }

FontSelectionValue SystemFontDatabaseCoreText::systemFontShorthandWeight(FontShorthand)
{
    return normalWeightValue();
}

void SystemFontDatabaseCoreText::clear() { m_systemFontCache.clear(); }

// Static helpers — all unused stubs.
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::smallCaptionFontDescriptor() { return { }; }
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::menuFontDescriptor() { return { }; }
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::statusBarFontDescriptor() { return { }; }
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::miniControlFontDescriptor() { return { }; }
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::smallControlFontDescriptor() { return { }; }
RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::controlFontDescriptor() { return { }; }

RetainPtr<CTFontRef> SystemFontDatabaseCoreText::createSystemUIFont(const CascadeListParameters&, CFStringRef) { return { }; }
RetainPtr<CTFontRef> SystemFontDatabaseCoreText::createSystemDesignFont(SystemFontKind, const CascadeListParameters&) { return { }; }
RetainPtr<CTFontRef> SystemFontDatabaseCoreText::createTextStyleFont(const CascadeListParameters&) { return { }; }

RetainPtr<CTFontRef> SystemFontDatabaseCoreText::createFontByApplyingWeightWidthItalicsAndFallbackBehavior(CTFontRef, CGFloat, CGFloat, bool, float, AllowUserInstalledFonts, CFStringRef)
{
    return { };
}

RetainPtr<CTFontDescriptorRef> SystemFontDatabaseCoreText::removeCascadeList(CTFontDescriptorRef desc)
{
    return desc;
}

Vector<RetainPtr<CTFontDescriptorRef>> SystemFontDatabaseCoreText::computeCascadeList(CTFontRef, CFStringRef)
{
    return { };
}

SystemFontDatabaseCoreText::CascadeListParameters SystemFontDatabaseCoreText::systemFontParameters(const FontDescription&, const AtomString&, SystemFontKind, AllowUserInstalledFonts)
{
    return { };
}

} // namespace WebCore
