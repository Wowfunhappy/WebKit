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
#import "AccessibilityObject.h"
#import "AXTextStateChangeIntent.h"
#import "WebAccessibilityObjectWrapperMac.h"

namespace WebCore {

// MAVERICKS_BACKPORT: no-op platform stubs replacing the isolated-tree/live-region implementations; must always compile on Mac (see header note).
void AXObjectCache::initializeUserDefaultValues() { }

// MAVERICKS_BACKPORT: upstream body — the ObjC accessibility wrapper works without the isolated
// tree, and WebKitTestRunner's _WKAccessibilityRootObjectForTesting requires a non-null wrapper
// (its AccessibilityUIElement::create RELEASE_ASSERTs the element).
void AXObjectCache::attachWrapper(AccessibilityObject& object)
{
    RetainPtr<WebAccessibilityObjectWrapper> wrapper = adoptNS([[WebAccessibilityObjectWrapper alloc] initWithAccessibilityObject:object]);
    object.setWrapper(wrapper.get());
}
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
