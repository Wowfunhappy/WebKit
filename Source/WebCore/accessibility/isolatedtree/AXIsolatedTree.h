// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// /*
//  * Copyright (C) 2019 Apple Inc. All rights reserved.
//  *
//  * Redistribution and use in source and binary forms, with or without
//  * modification, are permitted provided that the following conditions
//  * are met:
//  * 1. Redistributions of source code must retain the above copyright
//  *    notice, this list of conditions and the following disclaimer.
//  * 2. Redistributions in binary form must reproduce the above copyright
//  *    notice, this list of conditions and the following disclaimer in the
//  *    documentation and/or other materials provided with the distribution.
//  *
//  * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
//  * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
//  * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
//  * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
//  * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
//  * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//  * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
//  * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//  */
//
// (end MAVERICKS_BACKPORT restored block)
#pragma once

// MAVERICKS_BACKPORT: keystone band-aid — ENABLE_ACCESSIBILITY_ISOLATED_TREE flipped to 0 (in
// PlatformEnableCocoa.h). The full 742-line isolated-tree definition is compiled out, but several files
// include this header unconditionally and name the type, so keep a minimal stub class. Scaffolding for the
// keystone flag; feature-disable, not an SDK gap.
#include <wtf/RefCounted.h>

namespace WebCore {

// MAVERICKS_BACKPORT: minimal stub replacing the compiled-out isolated-tree definition (feature off).
class AXIsolatedTree : public RefCounted<AXIsolatedTree> {
public:
    // MAVERICKS_BACKPORT: only member needed by callers that include this header with the feature off.
    void updateNodeProperties(std::initializer_list<void*>) { }
};

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// void setPropertyIn(AXProperty, AXPropertyValueVariant&&, AXPropertyVector&, OptionSet<AXPropertyFlag>&);
//
// struct IsolatedObjectData {
//     Vector<AXID> childrenIDs;
//     AXPropertyVector properties;
//     Ref<AXIsolatedTree> tree;
//     Markable<AXID> parentID;
//     AXID axID;
//     AccessibilityRole role;
//     OptionSet<AXPropertyFlag> propertyFlags;
//     bool getsGeometryFromChildren;
//
//     IsolatedObjectData(Vector<AXID> childrenIDs, AXPropertyVector properties, Ref<AXIsolatedTree> tree, Markable<AXID> parentID, AXID axID, AccessibilityRole role, OptionSet<AXPropertyFlag> propertyFlags, bool getsGeometryFromChildren)
//         : childrenIDs(WTF::move(childrenIDs))
//         , properties(WTF::move(properties))
//         , tree(WTF::move(tree))
//         , parentID(parentID)
//         , axID(axID)
//         , role(role)
//         , propertyFlags(propertyFlags)
//         , getsGeometryFromChildren(getsGeometryFromChildren)
//     { }
//
//     IsolatedObjectData(const IsolatedObjectData&) = delete;
//     IsolatedObjectData(IsolatedObjectData&&) = default;
//
//     void setProperty(AXProperty property, AXPropertyValueVariant&& value)
//     {
//         properties.removeFirstMatching([&property] (const auto& propertyAndValue) {
//             return propertyAndValue.first == property;
//         });
//         setPropertyIn(property, WTF::move(value), properties, propertyFlags);
//     }
// };
//
// enum class DidTearDown : bool { No, Yes };
//
// DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(AXIsolatedTree);
// class AXIsolatedTree : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<AXIsolatedTree>
//     , public AXTreeStore<AXIsolatedTree> {
//     WTF_MAKE_NONCOPYABLE(AXIsolatedTree);
//     WTF_MAKE_TZONE_ALLOCATED(AXIsolatedTree);
//     friend WTF::TextStream& operator<<(WTF::TextStream&, AXIsolatedTree&);
//     friend void streamIsolatedSubtreeOnMainThread(TextStream&, const AXIsolatedTree&, AXID, const OptionSet<AXStreamOptions>&);
// public:
//     static RefPtr<AXIsolatedTree> create(AXObjectCache&);
//     // Creates a tree consisting of only the Scrollview and the WebArea objects. This tree is used as a temporary placeholder while the whole tree is being built.
//     static Ref<AXIsolatedTree> createEmpty(AXObjectCache&);
//     constexpr bool isEmptyContentTree() const { return m_isEmptyContentTree; }
//     virtual ~AXIsolatedTree();
//
//     static void removeTreeForFrameID(FrameIdentifier);
//
//     // Retrieve the tree for the frame ID of any LocalFrame
//     static RefPtr<AXIsolatedTree> treeForFrameID(FrameIdentifier);
//     static RefPtr<AXIsolatedTree> treeForFrameIDAlreadyLocked(FrameIdentifier);
//     AXObjectCache* axObjectCache() const;
//     constexpr AXGeometryManager* geometryManager() const { return m_geometryManager.get(); }
//
// #if ENABLE(ACCESSIBILITY_LOCAL_FRAME)
//     FrameGeometry frameGeometry() const { return m_frameGeometry; }
//     void setFrameGeometry(FrameGeometry&&);
// #endif
//
//     AXIsolatedObject* rootNode() { AX_ASSERT(!isMainThread()); return m_rootNode.get(); }
//     std::optional<AXID> pendingRootNodeID();
//     RefPtr<AXIsolatedObject> rootWebArea();
//     std::optional<AXID> focusedNodeID();
//     WEBCORE_EXPORT RefPtr<AXIsolatedObject> focusedNode();
//
//     bool unsafeHasObjectForID(AXID axID) const;
//     inline AXIsolatedObject* objectForID(AXID axID) const
//     {
//         AX_ASSERT(!isMainThread());
//
//         auto iterator = m_readerThreadNodeMap.find(axID);
//         if (iterator != m_readerThreadNodeMap.end())
//             return iterator->value.ptr();
//         return nullptr;
//     }
//     inline AXIsolatedObject* objectForID(std::optional<AXID> axID) const
//     {
//         return axID ? objectForID(*axID) : nullptr;
//     }
//     template<typename U> Vector<Ref<AXCoreObject>> objectsForIDs(const U&);
//
//     void generateSubtree(AccessibilityObject&);
//     bool shouldCreateNodeChange(AccessibilityObject&);
//     enum class ResolveNodeChanges : bool { No, Yes };
//     void updateChildrenForObjects(const ListHashSet<Ref<AccessibilityObject>>&);
//     void updateDependentProperties(AccessibilityObject&);
//     void updatePropertiesForSelfAndDescendants(AccessibilityObject&, const AXPropertySet&);
//     void updateFrame(AXID, IntRect&&);
//     void updateRootScreenRelativePosition();
//     void overrideNodeProperties(AXID, AXPropertyVector&&);
//
//     double NODELETE loadingProgress();
//     void NODELETE updateLoadingProgress(double);
//
//     void addUnconnectedNode(Ref<AccessibilityObject>);
//     bool isUnconnectedNode(std::optional<AXID> axID) const { return axID && m_unconnectedNodes.contains(*axID); }
//     // Removes the corresponding isolated object and all descendants from the m_nodeMap and queues their removal from the tree.
//     void removeNode(AXID, std::optional<AXID> /* parentID */);
//     // Removes the given node and all its descendants from m_nodeMap.
//     void removeSubtreeFromNodeMap(std::optional<AXID>, std::optional<AXID> /* parentID */);
//
//     void objectBecameIgnored(const AccessibilityObject& object)
//     {
//         objectChangedIgnoredState(object);
//         queueNodeUpdate(object.objectID(), { { AXProperty::IsIgnored, AXProperty::RevealableText } });
//     }
//     void objectBecameUnignored(const AccessibilityObject& object)
//     {
//         // We only cache minimal properties for ignored objects, so do a full node update to ensure all properties are cached.
//         queueNodeUpdate(object.objectID(), NodeUpdateOptions::nodeUpdate());
//         objectChangedIgnoredState(object);
//     }
//
//     // Both setPendingRootNodeLocked and setFocusedNodeID are called during the generation
//     // of the IsolatedTree.
//     // Focused node updates in AXObjectCache use setFocusNodeID.
//     void setPendingRootNodeID(AXID);
//     void NODELETE setPendingRootNodeIDLocked(AXID) WTF_REQUIRES_LOCK(m_changeLogLock);
//     void setFocusedNodeID(std::optional<AXID>);
//     void applyPendingRootNodeLocked() WTF_REQUIRES_LOCK(m_changeLogLock);
//
//     // Relationships between objects.
//     std::optional<ListHashSet<AXID>> relatedObjectIDsFor(const AXIsolatedObject&, AXRelation);
//     void markRelationsDirty() { m_relationsNeedUpdate = true; }
//     void updateRelations(HashMap<AXID, AXRelations>&&);
//
//     AXCoreObject::AccessibilityChildrenVector sortedLiveRegions();
//     AXCoreObject::AccessibilityChildrenVector sortedNonRootWebAreas();
//
//     void markMostRecentlyPaintedTextDirty() { m_mostRecentlyPaintedTextIsDirty = true; }
//     const HashMap<AXID, LineRange>& mostRecentlyPaintedText() const LIFETIME_BOUND { return m_mostRecentlyPaintedText; }
//
//     // Called on AX thread from WebAccessibilityObjectWrapper methods.
//     WEBCORE_EXPORT void applyPendingChanges();
//     void applyPendingChangesUnlessQueuedForDestruction();
//
//     // Returns DidTearDown::Yes if this tree was queued for destruction and tree teardown was performed.
//     // "Tear down" is very intentionally chosen wording, as it means we've cleared all internal
//     // member variables that could hold a strong-ref to the tree, but we can't actually force
//     // tree destruction until its ref-count falls to zero (which may or may not happen from the
//     // teardown depending on the outstanding ref-count elsewhere).
//     //
//     // Callers are responsible for removing the tree from isolatedTreeMap() when true is returned
//     // (hence the [[nodiscard]]).
//     [[nodiscard]] DidTearDown applyPendingChangesOrTearDown();
//
//     // Returns true if any tree has been queued for destruction but not yet cleaned up.
//     static bool anyTreeNeedsTearDown() { return s_anyTreeNeedsTearDown.load(std::memory_order_relaxed); }
//     static void clearAnyTreeNeedsTearDown() { s_anyTreeNeedsTearDown.store(false, std::memory_order_relaxed); }
//
//     constexpr AXTreeID treeID() const { return m_id; }
//     constexpr ProcessID processID() const { return m_processID; }
//     void setPageActivityState(OptionSet<ActivityState>);
//     OptionSet<ActivityState> pageActivityState() const;
//     // Use only if the s_storeLock is already held like in findAXTree.
//     WEBCORE_EXPORT OptionSet<ActivityState> NODELETE lockedPageActivityState() const;
//
//     AXTextMarkerRange selectedTextMarkerRange() { return m_selectedTextMarkerRange; }
//     void setSelectedTextMarkerRange(AXTextMarkerRange&&);
//
//     void sortedLiveRegionsDidChange(Vector<AXID>);
//     void sortedNonRootWebAreasDidChange(Vector<AXID>);
//
//     void setInitialSortedLiveRegions(Vector<AXID>);
//     void setInitialSortedNonRootWebAreas(Vector<AXID>);
//
//     void queueNodeUpdate(AXID, const NodeUpdateOptions&);
//     void queueNodeRemoval(const AccessibilityObject&);
//     void processQueuedNodeUpdates();
//
//     AXTextMarker firstMarker();
//     AXTextMarker lastMarker();
//
// private:
//     AXIsolatedTree(AXObjectCache&);
//     static void storeTree(AXObjectCache&, const Ref<AXIsolatedTree>&);
//     void reportLoadingProgress(double);
//
//     // Queue this isolated tree up to destroy itself on the secondary thread.
//     // We can't destroy the tree on the main-thread (by removing all `Ref`s to it)
//     // because it could be being used by the secondary thread to service an AX request.
//     void queueForDestruction();
//
//     void applyPendingChangesLocked() WTF_REQUIRES_LOCK(m_changeLogLock);
//     void clearTreeContentsLocked() WTF_REQUIRES_LOCK(m_changeLogLock);
//
//     static std::atomic<bool> s_anyTreeNeedsTearDown;
//
//     // rdar://161259641 (Figure out a way to enforce WTF_REQUIRES_LOCK when we might need to access it while already holding the lock)
//     static HashMap<FrameIdentifier, Ref<AXIsolatedTree>>& NODELETE treeFrameCache(); // WTF_REQUIRES_LOCK(s_storeLock);
//
//     void createEmptyContent(AccessibilityObject&);
//     constexpr bool isUpdatingSubtree() const { return m_rootOfSubtreeBeingUpdated; }
//     constexpr void updatingSubtree(AccessibilityObject* axObject) { m_rootOfSubtreeBeingUpdated = axObject; }
//
//     struct NodeChange {
//         IsolatedObjectData data;
// #if PLATFORM(COCOA)
//         RetainPtr<AccessibilityObjectWrapper> wrapper;
// #elif USE(ATSPI)
//         RefPtr<AccessibilityObjectWrapper> wrapper;
// #endif
//         explicit NodeChange(IsolatedObjectData&& isolatedData, RetainPtr<AccessibilityObjectWrapper> wrapper)
//             : data(WTF::move(isolatedData))
//             , wrapper(WTF::move(wrapper))
//         { }
//
//         NodeChange(const NodeChange&) = delete;
//         NodeChange(NodeChange&&) = default;
//     };
//
//     void updateChildren(AccessibilityObject&, ResolveNodeChanges = ResolveNodeChanges::Yes);
//     void updateNode(AccessibilityObject&);
//     void updateNodeProperties(AccessibilityObject&, const AXPropertySet&);
//
//     std::optional<NodeChange> nodeChangeForObject(Ref<AccessibilityObject>);
//     void collectNodeChangesForSubtree(AccessibilityObject&);
//     bool isCollectingNodeChanges() const { return m_isCollectingNodeChanges; }
//     void queueChange(NodeChange&&) WTF_REQUIRES_LOCK(m_changeLogLock);
//     void queueRemovals(Vector<AXID>&&);
//     void queueRemovalsLocked(Vector<AXID>&&) WTF_REQUIRES_LOCK(m_changeLogLock);
//     void queueRemovalsAndUnresolvedChanges();
//     Vector<NodeChange> resolveAppends();
//     void queueAppendsAndRemovals(Vector<NodeChange>&&, Vector<AXID>&&);
//
//     void objectChangedIgnoredState(const AccessibilityObject&);
//
//     const WeakPtr<AXObjectCache> m_axObjectCache;
//     RefPtr<AXGeometryManager> m_geometryManager;
//     // Reference to a temporary, empty content tree that this tree will replace. Used for updating the empty content tree while this is built.
//     RefPtr<AXIsolatedTree> m_replacingTree;
//     RefPtr<AccessibilityObject> m_rootOfSubtreeBeingUpdated;
//
//     // Stores the parent ID and children IDs for a given IsolatedObject.
//     struct ParentChildrenIDs {
//         Markable<AXID> parentID;
//         Vector<AXID> childrenIDs;
//     };
//     // Only accessed on the main thread.
//     // A representation of the tree's parent-child relationships. Each
//     // IsolatedObject must have one and only one entry in this map, that maps
//     // its ObjectID to its ParentChildrenIDs struct.
//     HashMap<AXID, ParentChildrenIDs> m_nodeMap;
//
//     // Only accessed on the main thread.
//     // Stores all nodes that are added via addUnconnectedNode, which do not get stored in m_nodeMap.
//     HashSet<AXID> m_unconnectedNodes;
//
//     // Only accessed on the main thread.
//     // The key is the ID of the object that will be resolved into an m_pendingAppends NodeChange.
//     HashSet<AXID> m_unresolvedPendingAppends;
//     // Only accessed on the main thread.
//     // While performing tree updates, we append nodes to this list that are no longer connected
//     // in the tree and should be removed. This list turns into m_pendingSubtreeRemovals when
//     // handed off to the secondary thread.
//     Vector<AXID> m_subtreesToRemove;
//     // Only accessed on the main thread.
//     // This is used when updating the isolated tree in response to dynamic children changes.
//     // It is required to protect objects from being incorrectly deleted when they are re-parented,
//     // as the original parent will want to queue it for removal, but we need to keep the object around
//     // for the new parent.
//     HashSet<AXID> m_protectedFromDeletionIDs;
//     // Only accessed on the main thread.
//     // Objects whose parent has changed, and said change needs to be synced to the secondary thread.
//     HashSet<AXID> m_needsParentUpdate;
//
//     // Only accessed on AX thread.
//     HashMap<AXID, Ref<AXIsolatedObject>> m_readerThreadNodeMap;
//     RefPtr<AXIsolatedObject> m_rootNode;
//
//     // Written to by main thread under lock, accessed and applied by AX thread.
//     Markable<AXID> m_pendingRootNodeID WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     Vector<NodeChange> m_pendingAppends WTF_GUARDED_BY_LOCK(m_changeLogLock); // Nodes to be added to the tree and platform-wrapped.
//     Vector<AXPropertyChange> m_pendingPropertyChanges WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     HashSet<AXID> m_pendingSubtreeRemovals WTF_GUARDED_BY_LOCK(m_changeLogLock); // Nodes whose subtrees are to be removed from the tree.
//     Vector<std::pair<AXID, Vector<AXID>>> m_pendingChildrenUpdates WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     HashSet<AXID> m_pendingProtectedFromDeletionIDs WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     HashMap<AXID, AXID> m_pendingParentUpdates WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     Markable<AXID> m_pendingFocusedNodeID WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     std::optional<Vector<AXID>> m_pendingSortedLiveRegionIDs WTF_GUARDED_BY_LOCK(m_changeLogLock);
//
//     // These three are placed here to fit in padding that would otherwise be between m_pendingSortedLiveRegionIDs and m_pendingSortedNonRootWebAreaIDs.
//     OptionSet<ActivityState> m_pageActivityState;
//     bool m_isEmptyContentTree { false };
//     bool m_queuedForDestruction WTF_GUARDED_BY_LOCK(m_changeLogLock) { false };
//
//     std::optional<Vector<AXID>> m_pendingSortedNonRootWebAreaIDs WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     std::optional<HashMap<AXID, LineRange>> m_pendingMostRecentlyPaintedText WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     std::optional<HashMap<AXID, AXRelations>> m_pendingRelations WTF_GUARDED_BY_LOCK(m_changeLogLock);
//     std::optional<AXTextMarkerRange> m_pendingSelectedTextMarkerRange WTF_GUARDED_BY_LOCK(m_changeLogLock);
// #if ENABLE(ACCESSIBILITY_LOCAL_FRAME)
//     std::optional<FrameGeometry> m_pendingFrameGeometry WTF_GUARDED_BY_LOCK(m_changeLogLock);
// #endif
//     Markable<AXID> m_focusedNodeID;
//     std::atomic<double> m_loadingProgress { 0 };
//     std::atomic<double> m_processingProgress { 1 };
//
//     // Only accessed on the accessibility thread.
//     Vector<AXID> m_sortedLiveRegionIDs;
//     Vector<AXID> m_sortedNonRootWebAreaIDs;
//     HashMap<AXID, LineRange> m_mostRecentlyPaintedText;
//     HashMap<AXID, AXRelations> m_relations;
// #if ENABLE(ACCESSIBILITY_LOCAL_FRAME)
//     FrameGeometry m_frameGeometry;
// #endif
//
//     // Set to true by the AXObjectCache and false by AXIsolatedTree.
//     // Both are only to be used on the main-thread.
//     bool m_relationsNeedUpdate { true };
//     bool m_mostRecentlyPaintedTextIsDirty { true };
//
//     Lock m_changeLogLock;
//
//     // Only accessed on the main thread.
//     bool m_isCollectingNodeChanges;
//
//     AXTextMarkerRange m_selectedTextMarkerRange;
//     const ProcessID m_processID { legacyPresentingApplicationPID() };
//
//     // Queued node updates used for building a new tree snapshot.
//     ListHashSet<AXID> m_needsUpdateChildren;
//     ListHashSet<AXID> m_needsUpdateNode;
//     HashMap<AXID, AXPropertySet> m_needsPropertyUpdates;
//     // The key is the ID of the node being removed. The value is the ID of the parent in the core tree (if it exists).
//     HashMap<AXID, std::optional<AXID>> m_needsNodeRemoval;
// };
//
// IsolatedObjectData createIsolatedObjectData(const Ref<AccessibilityObject>&, Ref<AXIsolatedTree>);
// std::optional<AXPropertyFlag> NODELETE convertToPropertyFlag(AXProperty);
//
// inline AXObjectCache* AXIsolatedTree::axObjectCache() const
// {
//     AX_ASSERT(isMainThread());
//     return m_axObjectCache.get();
// }
//
// template<typename U>
// inline Vector<Ref<AXCoreObject>> AXIsolatedTree::objectsForIDs(const U& axIDs)
// {
//     AX_ASSERT(!isMainThread());
//
//     Vector<Ref<AXCoreObject>> result;
//     result.reserveInitialCapacity(axIDs.size());
//     for (const auto& axID : axIDs) {
//         if (RefPtr object = objectForID(axID))
//             result.append(object.releaseNonNull());
//     }
//     result.shrinkToFit();
//     return result;
// }
//
// (end MAVERICKS_BACKPORT restored block)
} // namespace WebCore
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//
// #endif
// (end MAVERICKS_BACKPORT restored block)
