/*
 * Copyright (C) 2012-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "RemoteLayerTreeHost.h"

#import "AuxiliaryProcessProxy.h"
#import "LayerProperties.h"
#import "Logging.h"
#import "RemoteLayerTreeCommitBundle.h"
#import "RemoteLayerTreeDrawingAreaProxy.h"
#import "RemoteLayerTreePropertyApplier.h"
#import "RemoteLayerTreeTransaction.h"
// [10.9] #import "VideoPresentationManagerProxy.h"
#import "WKAnimationDelegate.h"
#import "WebPageProxy.h"
#import "WebProcessProxy.h"
#import "WindowKind.h"
#import <QuartzCore/QuartzCore.h>
#import <WebCore/DestinationColorSpace.h>
#import <WebCore/GraphicsContextCG.h>
#import <WebCore/IOSurface.h>
#import <WebCore/PlatformLayer.h>
#import <WebCore/ShareableBitmap.h>
#import <WebCore/WebCoreCALayerExtras.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

#if HAVE(MATERIAL_HOSTING)
#import "WKMaterialHostingSupport.h"
#endif

#if PLATFORM(IOS_FAMILY)
#import <UIKit/UIView.h>
#if ENABLE(MODEL_PROCESS)
#import "ModelPresentationManagerProxy.h"
#endif
#endif

#import <pal/cocoa/CoreMaterialSoftLink.h>
#import <pal/cocoa/QuartzCoreSoftLink.h>

namespace WebKit {
using namespace WebCore;

#define REMOTE_LAYER_TREE_HOST_RELEASE_LOG(...) RELEASE_LOG(ViewState, __VA_ARGS__)

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteLayerTreeHost);

RemoteLayerTreeHost::RemoteLayerTreeHost(RemoteLayerTreeDrawingAreaProxy& drawingArea)
    : m_drawingArea(drawingArea)
{
}

RemoteLayerTreeHost::~RemoteLayerTreeHost()
{
    // 10.9 backport: Safari quit crashes via std::terminate from this dtor.
    // The previous @try only wrapped the explicit body; the IMPLICIT member
    // destructors (m_nodes Ref<>, m_destroyedLayerGraveyard CALayer release,
    // m_animationDelegates WKAnimationDelegate release) ran AFTER the @try
    // returned and could throw NSException from CALayer dealloc → std::terminate.
    // Explicitly clear every container that releases ObjC/Ref objects inside
    // the @try so any thrown NSException is caught.
    try {
        @try {
            for (auto& delegate : m_animationDelegates.values())
                [delegate.get() invalidate];

            clearLayers();
            m_animationDelegates.clear();
            m_destroyedLayerGraveyard.clear();
            m_hostingLayers.clear();
            m_hostedLayers.clear();
            m_hostedLayersInProcess.clear();
            m_nodes.clear();
#if HAVE(AVKIT)
            m_videoLayers.clear();
#endif
        } @catch (NSException *) { }
    } catch (...) { }
}

RemoteLayerTreeDrawingAreaProxy& RemoteLayerTreeHost::drawingArea() const
{
    return *m_drawingArea;
}

bool RemoteLayerTreeHost::replayDynamicContentScalingDisplayListsIntoBackingStore() const
{
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    RefPtr page = m_drawingArea->page();
    return page && protect(page->preferences())->replayCGDisplayListsIntoBackingStore();
#else
    return false;
#endif
}

bool RemoteLayerTreeHost::threadedAnimationsEnabled() const
{
    if (RefPtr page = drawingArea().page()) {
        Ref preferences = page->preferences();
        return preferences->threadedScrollDrivenAnimationsEnabled() || preferences->threadedTimeBasedAnimationsEnabled();
    }
    return false;
}

bool RemoteLayerTreeHost::cssUnprefixedBackdropFilterEnabled() const
{
    RefPtr page = drawingArea().page();
    return page && protect(page->preferences())->cssUnprefixedBackdropFilterEnabled();
}

#if PLATFORM(MAC)
bool RemoteLayerTreeHost::updateBannerLayers(const std::optional<MainFrameData>& mainFrameData)
{
    if (!mainFrameData)
        return false;

    RetainPtr scrolledContentsLayer = layerForID(mainFrameData->scrolledContentsLayerID);
    if (!scrolledContentsLayer)
        return false;

    auto updateBannerLayer = [](CALayer *bannerLayer, CALayer *scrolledContentsLayer) -> bool {
        if (!bannerLayer)
            return false;

        if ([bannerLayer superlayer] == scrolledContentsLayer)
            return false;

        [scrolledContentsLayer addSublayer:bannerLayer];
        return true;
    };

    RefPtr page = drawingArea().page();
    if (!page)
        return false;

    bool headerBannerLayerChanged = updateBannerLayer(protect(page->headerBannerLayer()).get(), scrolledContentsLayer.get());
    bool footerBannerLayerChanged = updateBannerLayer(protect(page->footerBannerLayer()).get(), scrolledContentsLayer.get());
    return headerBannerLayerChanged || footerBannerLayerChanged;
}
#endif

bool RemoteLayerTreeHost::updateLayerTree(const IPC::Connection& connection, const RemoteLayerTreeTransaction& transaction, const std::optional<MainFrameData>& mainFrameData, float indicatorScaleFactor)
{
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host PID %d] updateLayerTree: drawingArea=%p createdLayers=%lu changedLayers=%lu rootLayerID=%llu mainFrameData=%d graveyard=%lu\n",getpid(),m_drawingArea.get(),(unsigned long)transaction.createdLayers().size(),(unsigned long)transaction.changedLayerProperties().size(),(unsigned long long)(transaction.rootLayerID() ? transaction.rootLayerID()->object().toUInt64() : 0),(int)!!mainFrameData,(unsigned long)m_destroyedLayerGraveyard.size());fclose(_d);}}
    if (!m_drawingArea)
        return false;
    // 10.9 backport: keep prior commit's destroyed CALayers alive through this
    // commit so CA's insert_sublayer can safely dereference stale superlayer
    // pointers. Drained at function end via local.
    auto previousGraveyard = std::exchange(m_destroyedLayerGraveyard, { });

    RefPtr sender = AuxiliaryProcessProxy::fromConnection(connection);
    if (!sender) {
        ASSERT_NOT_REACHED();
        return false;
    }
    auto processIdentifier = sender->coreProcessIdentifier();

    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host-preCreateLoop PID %d] createdLayers.size=%lu\n", getpid(), (unsigned long)transaction.createdLayers().size()); fclose(_d);}}
    int createdCount = 0;
    for (const auto& createdLayer : transaction.createdLayers()) {
        ++createdCount;
        createLayer(createdLayer);
    }
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host-postCreateLoop PID %d] createdCount=%d\n", getpid(), createdCount); fclose(_d);}}

    bool rootLayerChanged = false;
    RefPtr rootNode = nodeForID(transaction.rootLayerID());
    
    if (!rootNode)
        REMOTE_LAYER_TREE_HOST_RELEASE_LOG("%p RemoteLayerTreeHost::updateLayerTree - failed to find root layer with ID %llu", this, transaction.rootLayerID() ? transaction.rootLayerID()->object().toUInt64() : 0);

    if (m_rootNode.get() != rootNode.get() && mainFrameData) {
        m_rootNode = rootNode;
        rootLayerChanged = true;
    }

    struct LayerAndClone {
        PlatformLayerIdentifier layerID;
        PlatformLayerIdentifier cloneLayerID;
    };
    Vector<LayerAndClone> clonesToUpdate;

    {
        const auto& clp = transaction.changedLayerProperties();
        FILE *_d=((FILE*)0);
        if (_d) {
            fprintf(_d,"[ui-host-preHierLoop PID %d] clp.size=%lu createdLayers.size=%lu\n",
                getpid(), (unsigned long)clp.size(), (unsigned long)transaction.createdLayers().size());
            fclose(_d);
        }
    }
    int hierIter = 0;
    for (auto& [layerID, properties] : transaction.changedLayerProperties()) {
        ++hierIter;
        RefPtr node = nodeForID(layerID);
        ASSERT(node);

        if (!node) {
            // We have evidence that this can still happen, but don't know how (see r241899 for one already-fixed cause).
            REMOTE_LAYER_TREE_HOST_RELEASE_LOG("%p RemoteLayerTreeHost::updateLayerTree - failed to find layer with ID %llu", this, layerID.object().toUInt64());
            continue;
        }

        RemoteLayerTreePropertyApplier::applyHierarchyUpdates(*node, properties.get(), m_nodes);
    }
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host-postHierLoop PID %d] hierIter=%d clp.size=%lu\n", getpid(), hierIter, (unsigned long)transaction.changedLayerProperties().size()); fclose(_d);}}

    if (auto contextHostedID = transaction.remoteContextHostedIdentifier()) {
        m_hostedLayers.set(*contextHostedID, rootNode->layerID());
        m_hostedLayersInProcess.ensure(processIdentifier, [] {
            return HashSet<WebCore::PlatformLayerIdentifier>();
        }).iterator->value.add(rootNode->layerID());
        rootNode->setRemoteContextHostedIdentifier(*contextHostedID);
        if (RefPtr remoteRootNode = nodeForID(m_hostingLayers.getOptional(*contextHostedID)))
            rootNode->addToHostingNode(*remoteRootNode);
    }

#if ENABLE(THREADED_ANIMATIONS)
    // FIXME: with site isolation, a single process can send multiple transactions.
    // https://bugs.webkit.org/show_bug.cgi?id=301261
    if (threadedAnimationsEnabled() && !transaction.timelinesUpdate().isEmpty())
        protect(*m_drawingArea)->updateTimelinesRegistration(processIdentifier, transaction.timelinesUpdate(), MonotonicTime::now());
#endif

    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host-prePropLoop PID %d] entering second loop, size=%lu\n", getpid(), (unsigned long)transaction.changedLayerProperties().size()); fclose(_d);}}
    int found = 0, missing = 0, withBackingStore = 0;
    bool isLargeTxn = transaction.changedLayerProperties().size() > 5;
    for (auto& changedLayer : transaction.changedLayerProperties()) {
        auto layerID = changedLayer.key;
        const auto& properties = changedLayer.value.get();

        RefPtr node = nodeForID(layerID);
        ASSERT(node);

        if (!node) {
            ++missing;
            // We have evidence that this can still happen, but don't know how (see r241899 for one already-fixed cause).
            REMOTE_LAYER_TREE_HOST_RELEASE_LOG("%p RemoteLayerTreeHost::updateLayerTree - failed to find layer with ID %llu", this, layerID.object().toUInt64());
            continue;
        }
        ++found;
        bool hasBSC = properties.changedProperties.contains(LayerChange::BackingStoreChanged);
        bool hasBSAC = properties.changedProperties.contains(LayerChange::BackingStoreAttachmentChanged);
        if (hasBSC)
            ++withBackingStore;
        if (isLargeTxn) {
            FILE *_d=((FILE*)0);
            if(_d){
                fprintf(_d,"[ui-host-layer PID %d] layerID=%llu mask=0x%llx bsc=%d bsac=%d hasProps=%d\n",
                    getpid(), (unsigned long long)layerID.object().toUInt64(),
                    (unsigned long long)properties.changedProperties.toRaw(),
                    (int)hasBSC, (int)hasBSAC,
                    (int)!!properties.backingStoreOrProperties.properties.get());
                fclose(_d);
            }
        }

        if (properties.changedProperties.contains(LayerChange::ClonedContentsChanged) && properties.clonedLayerID)
            clonesToUpdate.append({ layerID, *properties.clonedLayerID });

        RemoteLayerTreePropertyApplier::applyProperties(*node, this, properties, m_nodes);

        if (m_isDebugLayerTreeHost) {
            RetainPtr layer = node->layer();
            if (properties.changedProperties.contains(LayerChange::BorderWidthChanged))
                layer.get().borderWidth = properties.borderWidth / indicatorScaleFactor;
            layer.get().masksToBounds = false;
        }
    }
    
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-host-iter PID %d] iterated changedLayers: found=%d missing=%d withBackingStore=%d\n", getpid(), found, missing, withBackingStore); fclose(_d);}}

    // 10.9 backport: CATransformLayer on Mavericks doesn't implement
    // -[CALayer contents] / -setContents:. Sending either raises
    // NSInvalidArgumentException and crashes UIProcess. Skip the contents
    // copy/clear when either layer is a CATransformLayer (they don't have
    // contents to begin with — they only composite sublayers' transforms).
    for (const auto& layerAndClone : clonesToUpdate) {
        RetainPtr destL = protect(layerForID(layerAndClone.layerID));
        RetainPtr srcL = protect(layerForID(layerAndClone.cloneLayerID));
        if ([destL respondsToSelector:@selector(setContents:)]
            && [srcL respondsToSelector:@selector(contents)]) {
            destL.get().contents = srcL.get().contents;
        }
    }

    for (auto& destroyedLayer : transaction.destroyedLayers())
        layerWillBeRemoved(processIdentifier, destroyedLayer);

    // Drop the contents of any layers which were unparented; the Web process will re-send
    // the backing store in the commit that reparents them.
    for (auto& newlyUnreachableLayerID : transaction.layerIDsWithNewlyUnreachableBackingStore()) {
        RefPtr node = nodeForID(newlyUnreachableLayerID);
        ASSERT(node);
        if (node) {
            RetainPtr l = protect(node->layer());
            if ([l respondsToSelector:@selector(setContents:)])
                l.get().contents = nullptr;
            node->setAsyncContentsIdentifier(std::nullopt);
        }
    }

#if PLATFORM(MAC)
    if (updateBannerLayers(mainFrameData))
        rootLayerChanged = true;
#endif

    return rootLayerChanged;
}

void RemoteLayerTreeHost::asyncSetLayerContents(PlatformLayerIdentifier layerID, WebKit::RemoteLayerBackingStoreProperties&& properties)
{
    RefPtr node = nodeForID(layerID);
    if (!node)
        return;

    node->applyBackingStore(this, properties);
}

RemoteLayerTreeNode* RemoteLayerTreeHost::nodeForID(std::optional<PlatformLayerIdentifier> layerID) const
{
    if (!layerID)
        return nullptr;

    return m_nodes.get(*layerID);
}

void RemoteLayerTreeHost::layerWillBeRemoved(WebCore::ProcessIdentifier processIdentifier, WebCore::PlatformLayerIdentifier layerID)
{
    auto animationDelegateIter = m_animationDelegates.find(layerID);
    if (animationDelegateIter != m_animationDelegates.end()) {
        [animationDelegateIter->value invalidate];
        m_animationDelegates.remove(animationDelegateIter);
    }

    if (auto node = m_nodes.take(layerID)) {
        // 10.9 backport: keep this layer alive until the next commit so any
        // surviving children with a stale _superlayer pointer to it can be
        // safely re-parented by CA's insert_sublayer (which dereferences the
        // old parent to call remove_sublayer).
        m_destroyedLayerGraveyard.append(node->layer());
#if ENABLE(THREADED_ANIMATIONS)
        animationsWereRemovedFromNode(*node);
#endif
        if (auto hostingIdentifier = node->remoteContextHostingIdentifier())
            m_hostingLayers.remove(*hostingIdentifier);
        if (auto hostedIdentifier = node->remoteContextHostedIdentifier()) {
            if (auto layerID = m_hostedLayers.takeOptional(*hostedIdentifier)) {
                auto it = m_hostedLayersInProcess.find(processIdentifier);
                if (it != m_hostedLayersInProcess.end()) {
                    it->value.remove(*layerID);
                    if (it->value.isEmpty())
                        m_hostedLayersInProcess.remove(it);
                }
            }
        }
    }

#if HAVE(AVKIT)
    auto videoLayerIter = m_videoLayers.find(layerID);
    if (videoLayerIter != m_videoLayers.end()) {
        RefPtr page = drawingArea().page();
// [10.9]         if (RefPtr videoManager = page ? (WebKit::VideoPresentationManagerProxy*)nullptr : nullptr)
// [10.9]             videoManager->willRemoveLayerForID(videoLayerIter->value);
        m_videoLayers.remove(videoLayerIter);
    }
#endif

#if PLATFORM(IOS_FAMILY) && ENABLE(MODEL_PROCESS)
    if (m_modelLayers.contains(layerID)) {
        RefPtr page = drawingArea().page();
        if (auto modelPresentationManager = page ? page->modelPresentationManagerProxy() : nullptr)
            modelPresentationManager->invalidateModel(layerID);
        m_modelLayers.remove(layerID);
    }
#endif
}

void RemoteLayerTreeHost::animationDidStart(std::optional<WebCore::PlatformLayerIdentifier> layerID, CAAnimation *animation, MonotonicTime startTime)
{
    if (!m_drawingArea)
        return;

    RetainPtr layer = layerForID(layerID);
    if (!layer)
        return;

    String animationKey;
    for (NSString *key in [layer animationKeys]) {
        if ([layer animationForKey:key] == animation) {
            animationKey = key;
            break;
        }
    }

    if (!animationKey.isEmpty())
        protect(drawingArea())->acceleratedAnimationDidStart(*layerID, animationKey, startTime);
}

void RemoteLayerTreeHost::animationDidEnd(std::optional<WebCore::PlatformLayerIdentifier> layerID, CAAnimation *animation)
{
    if (!m_drawingArea)
        return;

    RetainPtr layer = layerForID(layerID);
    if (!layer)
        return;

    String animationKey;
    for (NSString *key in [layer animationKeys]) {
        if ([layer animationForKey:key] == animation) {
            animationKey = key;
            break;
        }
    }

    if (!animationKey.isEmpty())
        protect(drawingArea())->acceleratedAnimationDidEnd(*layerID, animationKey);
}

void RemoteLayerTreeHost::detachFromDrawingArea()
{
    m_drawingArea = nullptr;
}

void RemoteLayerTreeHost::clearLayers()
{
    for (auto& keyAndNode : m_nodes) {
        m_animationDelegates.remove(keyAndNode.key);
        protect(keyAndNode.value)->detachFromParent();
    }

    m_nodes.clear();
    m_rootNode = nullptr;
}

CALayer *RemoteLayerTreeHost::layerWithIDForTesting(WebCore::PlatformLayerIdentifier layerID) const
{
    return layerForID(layerID);
}

CALayer *RemoteLayerTreeHost::layerForID(std::optional<WebCore::PlatformLayerIdentifier> layerID) const
{
    RefPtr node = nodeForID(layerID);
    if (!node)
        return nil;
    return node->layer();
}


CALayer *RemoteLayerTreeHost::rootLayer() const
{
    return m_rootNode ? m_rootNode->layer() : nil;
}

void RemoteLayerTreeHost::createLayer(const RemoteLayerTreeTransaction::LayerCreationProperties& properties)
{
    ASSERT(!m_nodes.contains(*properties.layerID));

    auto node = makeNode(properties);
    RetainPtr layer = node->layer();
    if ([layer respondsToSelector:@selector(setUsesWebKitBehavior:)]) {
        [layer setUsesWebKitBehavior:YES];
        if ([layer isKindOfClass:[CATransformLayer class]])
            [layer setSortsSublayers:YES];
        else
            [layer setSortsSublayers:NO];
    }

    if (auto* hostIdentifier = std::get_if<WebCore::LayerHostingContextIdentifier>(&properties.additionalData)) {
        m_hostingLayers.set(*hostIdentifier, *properties.layerID);
        if (RefPtr hostedNode = nodeForID(m_hostedLayers.getOptional(*hostIdentifier)))
            hostedNode->addToHostingNode(*node);
    }

    m_nodes.add(*properties.layerID, node.releaseNonNull());
}

#if !PLATFORM(IOS_FAMILY)
RefPtr<RemoteLayerTreeNode> RemoteLayerTreeHost::makeNode(const RemoteLayerTreeTransaction::LayerCreationProperties& properties)
{
    auto makeWithLayer = [&] (RetainPtr<CALayer>&& layer) {
        return RemoteLayerTreeNode::create(*properties.layerID, properties.hostIdentifier(), WTF::move(layer));
    };

    switch (properties.type) {
    case PlatformCALayer::LayerType::LayerTypeLayer:
    case PlatformCALayer::LayerType::LayerTypeWebLayer:
    case PlatformCALayer::LayerType::LayerTypeRootLayer:
    case PlatformCALayer::LayerType::LayerTypeSimpleLayer:
    case PlatformCALayer::LayerType::LayerTypeTiledBackingLayer:
    case PlatformCALayer::LayerType::LayerTypePageTiledBackingLayer:
    case PlatformCALayer::LayerType::LayerTypeTiledBackingTileLayer:
    case PlatformCALayer::LayerType::LayerTypeScrollContainerLayer:
#if ENABLE(MODEL_ELEMENT)
    case PlatformCALayer::LayerType::LayerTypeModelLayer:
#endif
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    case PlatformCALayer::LayerType::LayerTypeSeparatedImageLayer:
#endif
    case PlatformCALayer::LayerType::LayerTypeHost:
    case PlatformCALayer::LayerType::LayerTypeContentsProvidedLayer: {
        auto layer = RemoteLayerTreeNode::createWithPlainLayer(*properties.layerID);
        // So that the scrolling thread's performance logging code can find all the tiles, mark this as being a tile.
        if (properties.type == PlatformCALayer::LayerType::LayerTypeTiledBackingTileLayer)
            [protect(layer->layer()) setValue:@YES forKey:@"isTile"];
        return layer;
    }

    case PlatformCALayer::LayerType::LayerTypeTransformLayer:
        return makeWithLayer(adoptNS([[CATransformLayer alloc] init]));

    case PlatformCALayer::LayerType::LayerTypeBackdropLayer:
        return makeWithLayer(adoptNS([(NSClassFromString(@"CABackdropLayer") ?: [CALayer class]) new]));

#if HAVE(CORE_MATERIAL)
    case PlatformCALayer::LayerType::LayerTypeMaterialLayer:
        return makeWithLayer(adoptNS([PAL::allocMTMaterialLayerInstance() init]));
#endif

#if HAVE(MATERIAL_HOSTING)
    case PlatformCALayer::LayerType::LayerTypeMaterialHostingLayer: {
        if (![WKMaterialHostingSupport isMaterialHostingAvailable])
            return makeWithLayer(adoptNS([[CALayer alloc] init]));

        return makeWithLayer([WKMaterialHostingSupport hostingLayer]);
    }
#endif

    case PlatformCALayer::LayerType::LayerTypeCustom:
    case PlatformCALayer::LayerType::LayerTypeAVPlayerLayer:
        if (m_isDebugLayerTreeHost)
            return RemoteLayerTreeNode::createWithPlainLayer(*properties.layerID);

#if HAVE(AVKIT)
        if (properties.videoElementData) {
            RefPtr page = drawingArea().page();
// [10.9]             if (RefPtr videoManager = page ? (WebKit::VideoPresentationManagerProxy*)nullptr : nullptr) {
// [10.9]                 m_videoLayers.add(*properties.layerID, properties.videoElementData->playerIdentifier);
// [10.9]                 return makeWithLayer(videoManager->createLayerWithID(properties.videoElementData->playerIdentifier, { properties.hostingContextID() }, properties.videoElementData->initialSize, properties.videoElementData->naturalSize, properties.hostingDeviceScaleFactor()));
// [10.9]             }
        }
#endif

        return makeWithLayer([CALayer _web_renderLayerWithContextID:properties.hostingContextID() shouldPreserveFlip:properties.preservesFlip()]);

    case PlatformCALayer::LayerType::LayerTypeShapeLayer:
        return makeWithLayer(adoptNS([[CAShapeLayer alloc] init]));
    }
    ASSERT_NOT_REACHED();
    return nullptr;
}
#endif

void RemoteLayerTreeHost::detachRootLayer()
{
    if (RefPtr rootNode = std::exchange(m_rootNode, nullptr).get())
        rootNode->detachFromParent();
}

#if ENABLE(THREADED_ANIMATIONS)
void RemoteLayerTreeHost::animationsWereAddedToNode(RemoteLayerTreeNode& node)
{
    protect(drawingArea())->animationsWereAddedToNode(node);
}

void RemoteLayerTreeHost::animationsWereRemovedFromNode(RemoteLayerTreeNode& node)
{
    protect(drawingArea())->animationsWereRemovedFromNode(node);
}

RefPtr<const RemoteAnimationTimeline> RemoteLayerTreeHost::timeline(const TimelineID& timelineID) const
{
    return protect(drawingArea())->timeline(timelineID);
}

RefPtr<const RemoteAnimationStack> RemoteLayerTreeHost::animationStackForNodeWithIDForTesting(WebCore::PlatformLayerIdentifier layerID) const
{
    if (RefPtr node = nodeForID(layerID))
        return node->animationStack();
    return nullptr;
}
#endif

void RemoteLayerTreeHost::remotePageProcessDidTerminate(WebCore::ProcessIdentifier processIdentifier)
{
    for (auto layerID : m_hostedLayersInProcess.take(processIdentifier)) {
        if (RefPtr node = nodeForID(layerID))
            node->removeFromHostingNode();
        layerWillBeRemoved(processIdentifier, layerID);
    }
}

} // namespace WebKit

#undef REMOTE_LAYER_TREE_HOST_RELEASE_LOG
