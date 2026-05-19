/*
 * macOS 10.9 backport: AXObjectCacheMac.mm reduced to no-op stubs.
 * The original file uses many 10.10+/10.13+ accessibility APIs and the
 * isolated tree feature, none of which are available or needed for our
 * "browse the modern web" goal.
 */

#include "config.h"

#if HAVE(ACCESSIBILITY)

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
void AXObjectCache::createIsolatedObjectIfNeeded(AccessibilityObject&) { }
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
bool AXObjectCache::clientSupportsIsolatedTree() { return false; }
bool AXObjectCache::isIsolatedTreeEnabled() { return false; }
void AXObjectCache::initializeAXThreadIfNeeded() { }
bool AXObjectCache::isAXThreadInitialized() { return false; }
bool AXObjectCache::shouldSpellCheck() { return true; }
AXCoreObject::AccessibilityChildrenVector AXObjectCache::sortedLiveRegions() { return { }; }
AXCoreObject::AccessibilityChildrenVector AXObjectCache::sortedNonRootWebAreas() { return { }; }
void AXObjectCache::addSortedObjects(Vector<Ref<AccessibilityObject>>&&, PreSortedObjectType) { }
void AXObjectCache::removeLiveRegion(AccessibilityObject&) { }
void AXObjectCache::initializeSortedIDLists() { }
Seconds AXObjectCache::platformSelectedTextRangeDebounceInterval() const { return 0_s; }

} // namespace WebCore

#endif // HAVE(ACCESSIBILITY)
