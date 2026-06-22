// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE flipped to 0 (in
// PlatformEnableCocoa.h). The real 1111-line AXObjectCacheMac uses the isolated-tree / live-region /
// _AXSIsolatedTreeMode soft-link path (post-10.9 AX threading/SPI), compiled out by that flag; reduced
// here to no-op platform stubs. Feature-disable, not an SDK gap. These stubs must ALWAYS compile on Mac:
// AXObjectCache.h declares them out-of-line under #if PLATFORM(MAC), and the cross-platform
// AXObjectCache.cpp / TextCheckingHelper (spell-check) / AXCoreObjectCocoa call them unconditionally. No
// #if HAVE(ACCESSIBILITY) guard — HAVE_ACCESSIBILITY is undefined in modern WebKit so the guard was 0,
// which compiled the stubs out and dyld-halted WebContent on any text input via shouldSpellCheck().

#include "config.h"

#import "AXObjectCache.h"
#import "AccessibilityObject.h"
#import "AXTextStateChangeIntent.h"

namespace WebCore {

void AXObjectCache::initializeUserDefaultValues() { }
void AXObjectCache::attachWrapper(AccessibilityObject&) { }
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
