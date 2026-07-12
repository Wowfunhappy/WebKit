// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE flipped to 0 (in
// PlatformEnableCocoa.h). The real 1111-line AXObjectCacheMac uses the isolated-tree / live-region /
// _AXSIsolatedTreeMode soft-link path (post-10.9 AX threading/SPI), compiled out by that flag; reduced
// here to no-op platform stubs. Feature-disable, not an SDK gap. These stubs must ALWAYS compile on Mac:
// AXObjectCache.h declares them out-of-line under #if PLATFORM(MAC), and the cross-platform
// AXObjectCache.cpp / TextCheckingHelper (spell-check) / AXCoreObjectCocoa call them unconditionally. No
// #if HAVE(ACCESSIBILITY) guard — HAVE_ACCESSIBILITY is undefined in modern WebKit so the guard was 0,
// which compiled the stubs out and dyld-halted WebContent on any text input via shouldSpellCheck().

// MAVERICKS_BACKPORT: minimal include set for the stub bodies (the full file's AX-thread/soft-link headers are unused with the feature off).
#include "config.h"

// MAVERICKS_BACKPORT: only the headers the stub bodies reference (the AX-thread/soft-link imports are dropped with the feature off).
#import "AXObjectCache.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

#if PLATFORM(MAC)

#import "AXIsolatedObject.h"
#import "AXLiveRegionManager.h"
#import "AXLoggerBase.h"
#import "AXNotifications.h"
#import "AXObjectCacheInlines.h"
#import "AXSearchManager.h"
#import "AXUtilities.h"
MAVERICKS_BACKPORT */
#import "AccessibilityObject.h"
#import "AXTextStateChangeIntent.h"
#import "WebAccessibilityObjectWrapperMac.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import <pal/spi/cocoa/NSAccessibilitySPI.h>
#import <pal/spi/mac/HIServicesSPI.h>
#import <wtf/Scope.h>
#import <wtf/StdLibExtras.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

#if USE(APPLE_INTERNAL_SDK)
#import <ApplicationServices/ApplicationServicesPriv.h>
#endif

#import <pal/spi/cocoa/AccessibilitySupportSPI.h>
#import <pal/spi/cocoa/AccessibilitySupportSoftLink.h>

// Very large strings can negatively impact the performance of notifications, so this length is chosen to try to fit an average paragraph or line of text, but not allow strings to be large enough to hurt performance.
static const NSUInteger AXValueChangeTruncationLength = 1000;

// Check if platform provides enums for text change notifications
#ifndef AXTextStateChangeDefined
#define AXTextStateChangeDefined

typedef CF_ENUM(UInt32, AXTextStateChangeType)
{
    kAXTextStateChangeTypeUnknown,
    kAXTextStateChangeTypeEdit,
    kAXTextStateChangeTypeSelectionMove,
    kAXTextStateChangeTypeSelectionExtend,
    kAXTextStateChangeTypeSelectionBoundary
};

typedef CF_ENUM(UInt32, AXTextEditType)
{
    kAXTextEditTypeUnknown,
    kAXTextEditTypeDelete,
    kAXTextEditTypeInsert,
    kAXTextEditTypeTyping,
    kAXTextEditTypeDictation,
    kAXTextEditTypeCut,
    kAXTextEditTypePaste,
    kAXTextEditTypeAttributesChange
};

typedef CF_ENUM(UInt32, AXTextSelectionDirection)
{
    kAXTextSelectionDirectionUnknown = 0,
    kAXTextSelectionDirectionBeginning,
    kAXTextSelectionDirectionEnd,
    kAXTextSelectionDirectionPrevious,
    kAXTextSelectionDirectionNext,
    kAXTextSelectionDirectionDiscontiguous
};

typedef CF_ENUM(UInt32, AXTextSelectionGranularity)
{
    kAXTextSelectionGranularityUnknown,
    kAXTextSelectionGranularityCharacter,
    kAXTextSelectionGranularityWord,
    kAXTextSelectionGranularityLine,
    kAXTextSelectionGranularitySentence,
    kAXTextSelectionGranularityParagraph,
    kAXTextSelectionGranularityPage,
    kAXTextSelectionGranularityDocument,
    kAXTextSelectionGranularityAll
};

#endif // AXTextStateChangeDefined

static AXTextStateChangeType NODELETE platformChangeTypeForWebCoreChangeType(WebCore::AXTextStateChangeType changeType)
{
    switch (changeType) {
    case WebCore::AXTextStateChangeType::Unknown:
        return kAXTextStateChangeTypeUnknown;
    case WebCore::AXTextStateChangeType::Edit:
        return kAXTextStateChangeTypeEdit;
    case WebCore::AXTextStateChangeType::SelectionMove:
        return kAXTextStateChangeTypeSelectionMove;
    case WebCore::AXTextStateChangeType::SelectionExtend:
        return kAXTextStateChangeTypeSelectionExtend;
    case WebCore::AXTextStateChangeType::SelectionBoundary:
        return kAXTextStateChangeTypeSelectionBoundary;
    }
}

static AXTextEditType NODELETE platformEditTypeForWebCoreEditType(WebCore::AXTextEditType changeType)
{
    switch (changeType) {
    case WebCore::AXTextEditType::Unknown:
        return kAXTextEditTypeUnknown;
    case WebCore::AXTextEditType::Delete:
        return kAXTextEditTypeDelete;
    case WebCore::AXTextEditType::Insert:
        return kAXTextEditTypeInsert;
    case WebCore::AXTextEditType::Typing:
        return kAXTextEditTypeTyping;
    case WebCore::AXTextEditType::Dictation:
        return kAXTextEditTypeDictation;
    case WebCore::AXTextEditType::Cut:
        return kAXTextEditTypeCut;
    case WebCore::AXTextEditType::Paste:
        return kAXTextEditTypePaste;
    case WebCore::AXTextEditType::Replace:
        return kAXTextEditTypeUnknown; // Does not exist in platform enum.
    case WebCore::AXTextEditType::AttributesChange:
        return kAXTextEditTypeAttributesChange;
    }
}

static AXTextSelectionDirection NODELETE platformDirectionForWebCoreDirection(WebCore::AXTextSelectionDirection direction)
{
    switch (direction) {
    case WebCore::AXTextSelectionDirection::Unknown:
        return kAXTextSelectionDirectionUnknown;
    case WebCore::AXTextSelectionDirection::Beginning:
        return kAXTextSelectionDirectionBeginning;
    case WebCore::AXTextSelectionDirection::End:
        return kAXTextSelectionDirectionEnd;
    case WebCore::AXTextSelectionDirection::Previous:
        return kAXTextSelectionDirectionPrevious;
    case WebCore::AXTextSelectionDirection::Next:
        return kAXTextSelectionDirectionNext;
    case WebCore::AXTextSelectionDirection::Discontiguous:
        return kAXTextSelectionDirectionDiscontiguous;
    }
}

static AXTextSelectionGranularity NODELETE platformGranularityForWebCoreGranularity(WebCore::AXTextSelectionGranularity granularity)
{
    switch (granularity) {
    case WebCore::AXTextSelectionGranularity::Unknown:
        return kAXTextSelectionGranularityUnknown;
    case WebCore::AXTextSelectionGranularity::Character:
        return kAXTextSelectionGranularityCharacter;
    case WebCore::AXTextSelectionGranularity::Word:
        return kAXTextSelectionGranularityWord;
    case WebCore::AXTextSelectionGranularity::Line:
        return kAXTextSelectionGranularityLine;
    case WebCore::AXTextSelectionGranularity::Sentence:
        return kAXTextSelectionGranularitySentence;
    case WebCore::AXTextSelectionGranularity::Paragraph:
        return kAXTextSelectionGranularityParagraph;
    case WebCore::AXTextSelectionGranularity::Page:
        return kAXTextSelectionGranularityPage;
    case WebCore::AXTextSelectionGranularity::Document:
        return kAXTextSelectionGranularityDocument;
    case WebCore::AXTextSelectionGranularity::All:
        return kAXTextSelectionGranularityAll;
    }
}

// The simple Cocoa calls in this file don't throw exceptions.
MAVERICKS_BACKPORT */

namespace WebCore {

// MAVERICKS_BACKPORT: no-op platform stubs replacing the isolated-tree/live-region implementations; must always compile on Mac (see header note).
void AXObjectCache::initializeUserDefaultValues() { }

void AXObjectCache::attachWrapper(AccessibilityObject& object)
{
    RetainPtr<WebAccessibilityObjectWrapper> wrapper = adoptNS([[WebAccessibilityObjectWrapper alloc] initWithAccessibilityObject:object]);
    object.setWrapper(wrapper.get());
}
// MAVERICKS_BACKPORT: no-op platform notification / live-region / text-marker stubs — the isolated-tree implementations are compiled out with ENABLE_ACCESSIBILITY_ISOLATED_TREE=0 (see header note) and these must always compile on Mac.
void AXObjectCache::postPlatformNotification(AccessibilityObject&, AXNotification) { }
void AXObjectCache::postPlatformAnnouncementNotification(const String&) { }
void AXObjectCache::postPlatformARIANotifyNotification(AccessibilityObject&, const AriaNotifyData&) { }
void AXObjectCache::postPlatformLiveRegionNotification(AccessibilityObject&, const LiveRegionAnnouncementData&) { }
void AXObjectCache::onDocumentRenderTreeCreation(const Document&) { }
void AXObjectCache::deferSortForNewLiveRegion(Ref<AccessibilityObject>&&) { }
void AXObjectCache::queueUnsortedObject(Ref<AccessibilityObject>&&, PreSortedObjectType) { }
AXTextStateChangeIntent AXObjectCache::inferDirectionFromIntent(AccessibilityObject&, const AXTextStateChangeIntent& intent, const VisibleSelection&) { return intent; }
void AXObjectCache::postTextSelectionChangePlatformNotification(AccessibilityObject*, const AXTextStateChangeIntent&, const VisibleSelection&) { }
void AXObjectCache::postTextStateChangePlatformNotification(AccessibilityObject*, AXTextEditType, const String&, const VisiblePosition&) { }
void AXObjectCache::postUserInfoForChanges(AccessibilityObject&, AccessibilityObject&, RetainPtr<NSMutableArray>) { }
void AXObjectCache::postTextReplacementPlatformNotification(AccessibilityObject*, AXTextEditType, const String&, AXTextEditType, const String&, const VisiblePosition&) { }
void AXObjectCache::postTextReplacementPlatformNotificationForTextControl(AccessibilityObject*, const String&, const String&) { }
void AXObjectCache::frameLoadingEventPlatformNotification(RenderView*, AXLoadingEvent) { }
void AXObjectCache::platformHandleFocusedUIElementChanged(AccessibilityObject*, AccessibilityObject*) { }
void AXObjectCache::handleScrolledToAnchor(const Node&) { }
void AXObjectCache::platformPerformDeferredCacheUpdate() { }
bool AXObjectCache::clientIsInTestMode() { return false; }
bool AXObjectCache::shouldSpellCheck() { return true; }
AXCoreObject::AccessibilityChildrenVector AXObjectCache::sortedLiveRegions() { return { }; }
AXCoreObject::AccessibilityChildrenVector AXObjectCache::sortedNonRootWebAreas() { return { }; }
void AXObjectCache::addSortedObjects(Vector<Ref<AccessibilityObject>>&&, PreSortedObjectType) { }
void AXObjectCache::removeLiveRegion(AccessibilityObject&) { }
void AXObjectCache::initializeSortedIDLists() { }

} // namespace WebCore
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//
// #endif // PLATFORM(MAC)
// (end MAVERICKS_BACKPORT restored block)
