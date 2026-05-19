/*
 * Copyright (C) 2011-2025 Apple Inc. All rights reserved.
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
#import "TiledCoreAnimationDrawingArea.h"

#if ENABLE(TILED_CA_DRAWING_AREA)

#import "DrawingAreaProxyMessages.h"
#import "EventDispatcher.h"
#import "LayerHostingContext.h"
#import "LayerTreeContext.h"
#import "Logging.h"
#import "MessageSenderInlines.h"
#import "ViewGestureControllerMessages.h"
#import "WebDisplayRefreshMonitor.h"
#import "WebFrame.h"
#import "WebPage.h"
#import "WebPageCreationParameters.h"
#import "WebPageInlines.h"
#import "WebPageProxyMessages.h"
#import "WebPreferencesKeys.h"
#import "WebPreferencesStore.h"
#import "WebProcess.h"
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <QuartzCore/QuartzCore.h>
#import <WebCore/AsyncScrollingCoordinator.h>
#import <WebCore/ColorSpaceCG.h>
#import <WebCore/DebugPageOverlays.h>
#import <WebCore/DestinationColorSpace.h>
#import <WebCore/FrameInlines.h>
#import <WebCore/GraphicsContext.h>
#import <WebCore/GraphicsLayerCA.h>
#import <WebCore/LocalFrame.h>
#import <WebCore/LocalFrameView.h>
#import <WebCore/Page.h>
#import <WebCore/PlatformCAAnimationCocoa.h>
#import <WebCore/RenderView.h>
#import <WebCore/RunLoopObserver.h>
#import <WebCore/ScrollbarTheme.h>
#import <WebCore/ScrollingThread.h>
#import <WebCore/ScrollingTree.h>
#import <WebCore/Settings.h>
#import <WebCore/TiledBacking.h>
#import <WebCore/WebActionDisablingCALayerDelegate.h>
#import <WebCore/WindowEventLoop.h>
#import <wtf/MachSendRight.h>
#import <wtf/MainThread.h>
#import <wtf/MonotonicTime.h>
#import <wtf/SystemTracing.h>
#import <wtf/TZoneMallocInlines.h>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(TiledCoreAnimationDrawingArea);

TiledCoreAnimationDrawingArea::TiledCoreAnimationDrawingArea(WebPage& webPage, const WebPageCreationParameters& parameters)
    : DrawingArea(parameters.drawingAreaIdentifier, webPage)
    , m_isPaintingSuspended(!(parameters.activityState & ActivityState::IsVisible))
{
    m_hostingLayer = [CALayer layer];
    [m_hostingLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
    [m_hostingLayer setFrame:webPage.bounds()];
    [m_hostingLayer setOpaque:YES];
    [m_hostingLayer setGeometryFlipped:YES];

    m_renderingUpdateRunLoopObserver = makeUnique<RunLoopObserver>(RunLoopObserver::WellKnownOrder::RenderingUpdate, [this] {
        this->renderingUpdateRunLoopCallback();
    });

    m_postRenderingUpdateRunLoopObserver = makeUnique<RunLoopObserver>(RunLoopObserver::WellKnownOrder::PostRenderingUpdate, [this] {
        this->postRenderingUpdateRunLoopCallback();
    });

    updateLayerHostingContext();
    
    setColorSpace(parameters.colorSpace);

    if (!parameters.isProcessSwap)
        sendEnterAcceleratedCompositingModeIfNeeded();
}

TiledCoreAnimationDrawingArea::~TiledCoreAnimationDrawingArea()
{
    invalidateRenderingUpdateRunLoopObserver();
    invalidatePostRenderingUpdateRunLoopObserver();
    for (auto& callback : m_nextActivityStateChangeCallbacks)
        callback();
}

void TiledCoreAnimationDrawingArea::sendDidFirstLayerFlushIfNeeded()
{
    if (!m_rootLayer)
        return;

    if (!m_needsSendDidFirstLayerFlush)
        return;
    m_needsSendDidFirstLayerFlush = false;

    if (!m_layerHostingContext)
        return;

    // 10.9 backport: send the IPC SYNCHRONOUSLY here rather than going through
    // dispatch_async(main_queue). The original code used CATransaction commit
    // handlers (10.10+) to defer until commit; without them we used main_queue
    // dispatch as a stand-in. But main_queue is often jammed by the same
    // updateRendering pass that produced this flush, so the message could wait
    // a full second or more — that's the user-visible "5 sec white screen"
    // before any pixels appear, because UIProcess attaches CALayerHost only
    // upon receiving this message.
    LayerTreeContext layerTreeContext;
    layerTreeContext.contextID = m_layerHostingContext->cachedContextID();
    send(Messages::DrawingAreaProxy::DidFirstLayerFlush(0, layerTreeContext));
}

void TiledCoreAnimationDrawingArea::sendEnterAcceleratedCompositingModeIfNeeded()
{
    if (!m_needsSendEnterAcceleratedCompositingMode)
        return;
    m_needsSendEnterAcceleratedCompositingMode = false;

    LayerTreeContext layerTreeContext;
    layerTreeContext.contextID = m_layerHostingContext->cachedContextID();
    send(Messages::DrawingAreaProxy::EnterAcceleratedCompositingMode(0, layerTreeContext));
}

void TiledCoreAnimationDrawingArea::registerScrollingTree()
{
    protect(WebProcess::singleton().eventDispatcher())->addScrollingTreeForPage(Ref { m_webPage.get() });
}

void TiledCoreAnimationDrawingArea::unregisterScrollingTree()
{
    protect(WebProcess::singleton().eventDispatcher())->removeScrollingTreeForPage(Ref { m_webPage.get() });
}

void TiledCoreAnimationDrawingArea::setNeedsDisplay()
{
}

void TiledCoreAnimationDrawingArea::setNeedsDisplayInRect(const IntRect& rect)
{
}

void TiledCoreAnimationDrawingArea::setRootCompositingLayer(WebCore::Frame&, GraphicsLayer* graphicsLayer)
{
    RetainPtr rootLayer = graphicsLayer ? graphicsLayer->platformLayer() : nil;

    if (m_layerTreeStateIsFrozen) {
        m_pendingRootLayer = rootLayer.get();
        return;
    }

    m_pendingRootLayer = nullptr;
    setRootCompositingLayer(rootLayer.get());
}

void TiledCoreAnimationDrawingArea::updateRenderingWithForcedRepaint()
{
    if (m_layerTreeStateIsFrozen)
        return;

    protect(Ref { m_webPage.get() }->corePage())->forceRepaintAllFrames();
    updateRendering();
    [CATransaction flush];
    [CATransaction synchronize];
}

void TiledCoreAnimationDrawingArea::updateRenderingWithForcedRepaintAsync(WebPage& page, CompletionHandler<void()>&& completionHandler)
{
    if (m_layerTreeStateIsFrozen) {
        updateRenderingWithForcedRepaint();
        return completionHandler();
    }

    dispatchAfterEnsuringUpdatedScrollPosition([weakThis = WeakPtr { *this }, completionHandler = WTF::move(completionHandler)] () mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return completionHandler();
        Ref protectedPage = protectedThis->m_webPage.get();
        protect(protectedPage->drawingArea())->updateRenderingWithForcedRepaint();
        completionHandler();
    });
}

void TiledCoreAnimationDrawingArea::setLayerTreeStateIsFrozen(bool layerTreeStateIsFrozen)
{
    if (m_layerTreeStateIsFrozen == layerTreeStateIsFrozen)
        return;

    tracePoint(layerTreeStateIsFrozen ? LayerTreeFreezeStart : LayerTreeFreezeEnd);

    m_layerTreeStateIsFrozen = layerTreeStateIsFrozen;

    if (m_layerTreeStateIsFrozen) {
        invalidateRenderingUpdateRunLoopObserver();
        invalidatePostRenderingUpdateRunLoopObserver();
    } else {
        // Immediate flush as any delay in unfreezing can result in flashes.
        scheduleRenderingUpdateRunLoopObserver();
    }
}

bool TiledCoreAnimationDrawingArea::layerTreeStateIsFrozen() const
{
    return m_layerTreeStateIsFrozen;
}

void TiledCoreAnimationDrawingArea::triggerRenderingUpdate()
{
    if (m_layerTreeStateIsFrozen)
        return;

    // 10.9 backport: always schedule the observer immediately. Previously a
    // dispatch_after-based 60Hz throttle here meant that during link
    // navigation — when the OLD page was firing rAFs up to the moment of
    // click — the FIRST render of the new page was deferred via
    // dispatch_after on main_queue. main_queue is then jammed by the new
    // page's script execution, so the deferred render waits seconds behind
    // it, producing the user-visible "click link → white screen for ages"
    // pattern. CFRunLoopObserver's isScheduled() naturally dedups within a
    // single runloop tick, which is a tighter throttle than the dispatch_after
    // anyway, and the observer-driven path doesn't depend on main_queue
    // draining. Keep the rate-limit only as a recency record for diagnostics.
    m_lastRenderingTriggerTime = MonotonicTime::now();
    scheduleRenderingUpdateRunLoopObserver();
}

void TiledCoreAnimationDrawingArea::updatePreferences(const WebPreferencesStore& store)
{
    Ref webPage = m_webPage.get();
    Ref settings = webPage->corePage()->settings();

    // Fixed position elements need to be composited and create stacking contexts
    // in order to be scrolled by the ScrollingCoordinator.
    settings->setAcceleratedCompositingForFixedPositionEnabled(true);

    DebugPageOverlays::settingsChanged(*protect(webPage->corePage()));

    bool showTiledScrollingIndicator = settings->showTiledScrollingIndicator();
    if (showTiledScrollingIndicator == !!m_debugInfoLayer)
        return;

    updateDebugInfoLayer(showTiledScrollingIndicator);
}

void TiledCoreAnimationDrawingArea::updateRootLayers()
{
    if (!m_rootLayer) {
        [m_hostingLayer setSublayers:@[ ]];
        return;
    }

    RefPtr viewOverlayRootLayer = m_viewOverlayRootLayer;
    [m_hostingLayer setSublayers:viewOverlayRootLayer ? @[ m_rootLayer.get(), viewOverlayRootLayer->platformLayer() ] : @[ m_rootLayer.get() ]];
    
    if (m_debugInfoLayer)
        [m_hostingLayer addSublayer:m_debugInfoLayer.get()];
}

void TiledCoreAnimationDrawingArea::attachViewOverlayGraphicsLayer(WebCore::FrameIdentifier, GraphicsLayer* viewOverlayRootLayer)
{
    m_viewOverlayRootLayer = viewOverlayRootLayer;
    updateRootLayers();
    triggerRenderingUpdate();
}

void TiledCoreAnimationDrawingArea::mainFrameContentSizeChanged(WebCore::FrameIdentifier, const IntSize& size)
{
}

void TiledCoreAnimationDrawingArea::dispatchAfterEnsuringUpdatedScrollPosition(WTF::Function<void ()>&& function)
{
    RefPtr corePage = m_webPage->corePage();
    ASSERT(corePage);
    if (!corePage->scrollingCoordinator()) {
        function();
        return;
    }

    protect(corePage->scrollingCoordinator())->commitTreeStateIfNeeded();

    if (!m_layerTreeStateIsFrozen) {
        invalidateRenderingUpdateRunLoopObserver();
        invalidatePostRenderingUpdateRunLoopObserver();
    }

    ScrollingThread::dispatchBarrier([weakThis = WeakPtr { *this }, retainedPage = Ref { m_webPage.get() }, function = WTF::move(function)] {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;

        // It is possible for the drawing area to be destroyed before the bound block is invoked.
        if (!retainedPage->drawingArea())
            return;

        function();

        if (!protectedThis->m_layerTreeStateIsFrozen)
            protectedThis->scheduleRenderingUpdateRunLoopObserver();
    });
}

void TiledCoreAnimationDrawingArea::sendPendingNewlyReachedPaintingMilestones()
{
    if (!m_pendingNewlyReachedPaintingMilestones)
        return;

    Ref { m_webPage.get() }->send(Messages::WebPageProxy::DidReachLayoutMilestone(std::exchange(m_pendingNewlyReachedPaintingMilestones, { }), WallTime::now()));
}

void TiledCoreAnimationDrawingArea::dispatchAfterEnsuringDrawing(IPC::AsyncReplyID callbackID)
{
    m_pendingCallbackIDs.append(callbackID);
    triggerRenderingUpdate();
}

void TiledCoreAnimationDrawingArea::didCompleteRenderingUpdateDisplay()
{
    m_haveRegisteredHandlersForNextCommit = false;

    sendPendingNewlyReachedPaintingMilestones();
    DrawingArea::didCompleteRenderingUpdateDisplay();
    
    schedulePostRenderingUpdateRunLoopObserver();
}

void TiledCoreAnimationDrawingArea::addCommitHandlers()
{
    if (m_haveRegisteredHandlersForNextCommit)
        return;

    // 10.9 backport: +[CATransaction addCommitHandler:forPhase:] is 10.10+.
    // Skip registration entirely; the runloop observers in updateRendering
    // still drive the rendering cycle. willStart/didComplete callbacks won't
    // fire from CA's perspective.
    m_haveRegisteredHandlersForNextCommit = true;
}

void TiledCoreAnimationDrawingArea::updateRendering(UpdateRenderingType flushType)
{
    if (layerTreeStateIsFrozen())
        return;

    Ref webPage = m_webPage.get();
    if (!webPage->hasRootFrames()) [[unlikely]]
        return;

    @autoreleasepool {
        scaleViewToFitDocumentIfNeeded();

        webPage->updateRendering();
        webPage->flushPendingThemeColorChange();
        webPage->flushPendingPageExtendedBackgroundColorChange();
        webPage->flushPendingSampledPageTopColorChange();
        webPage->flushPendingEditorStateUpdate();
        webPage->flushPendingIntrinsicContentSizeUpdate();

        if (m_pendingRootLayer) {
            setRootCompositingLayer(m_pendingRootLayer.get());
            m_pendingRootLayer = nullptr;
        }

        FloatRect visibleRect = [m_hostingLayer frame];
        if (RefPtr localMainFrameView = webPage->localMainFrameView()) {
            if (auto exposedRect = localMainFrameView->viewExposedRect())
                visibleRect.intersect(*exposedRect);
        }

        // Because our view-relative overlay root layer is not attached to the main GraphicsLayer tree, we need to flush it manually.
        if (RefPtr layer = m_viewOverlayRootLayer)
            layer->flushCompositingState(visibleRect);

        addCommitHandlers();

        OptionSet<FinalizeRenderingUpdateFlags> flags;
        if (flushType == UpdateRenderingType::Normal)
            flags.add(FinalizeRenderingUpdateFlags::ApplyScrollingTreeLayerPositions);

        webPage->finalizeRenderingUpdate(flags);

        // If we have an active transient zoom, we want the zoom to win over any changes
        // that WebCore makes to the relevant layers, so re-apply our changes after flushing.
        if (m_transientZoomScale != 1)
            applyTransientZoomToLayers(m_transientZoomScale, m_transientZoomOrigin);

        if (!m_pendingCallbackIDs.isEmpty()) {
            send(Messages::DrawingAreaProxy::DispatchPresentationCallbacksAfterFlushingLayers(m_pendingCallbackIDs));
            m_pendingCallbackIDs.clear();
        }

        sendDidFirstLayerFlushIfNeeded();
        webPage->didUpdateRendering();
        handleActivityStateChangeCallbacksIfNeeded();
        invalidateRenderingUpdateRunLoopObserver();

        // 10.9 backport: explicitly flush CATransaction so layer changes
        // (especially scroll position deltas) propagate to the CAContext.
        // Normally CA auto-commits when CFRunLoop drains, but on Mavericks
        // the WebContent "main thread" doesn't run a true CFRunLoop.
        [CATransaction flush];
    }
}

void TiledCoreAnimationDrawingArea::handleActivityStateChangeCallbacks()
{
    if (!m_shouldHandleActivityStateChangeCallbacks)
        return;
    m_shouldHandleActivityStateChangeCallbacks = false;

    if (m_activityStateChangeID != ActivityStateChangeAsynchronous)
        Ref { m_webPage.get() }->send(Messages::WebPageProxy::DidUpdateActivityState());

    for (auto& callback : std::exchange(m_nextActivityStateChangeCallbacks, { }))
        callback();

    m_activityStateChangeID = ActivityStateChangeAsynchronous;
}

void TiledCoreAnimationDrawingArea::handleActivityStateChangeCallbacksIfNeeded()
{
    if (!m_shouldHandleActivityStateChangeCallbacks)
        return;

    // 10.9 backport: +currentState and +addCommitHandler:forPhase: are 10.10+.
    // Fall back to immediate execution (slightly less precise but works).
    handleActivityStateChangeCallbacks();
}

void TiledCoreAnimationDrawingArea::activityStateDidChange(OptionSet<ActivityState> changed, ActivityStateChangeID activityStateChangeID, CompletionHandler<void()>&& nextActivityStateChangeCallback)
{
    m_nextActivityStateChangeCallbacks.append(WTF::move(nextActivityStateChangeCallback));
    m_activityStateChangeID = std::max(m_activityStateChangeID, activityStateChangeID);

    if (changed & ActivityState::IsVisible) {
        if (m_webPage->isVisible())
            resumePainting();
        else
            suspendPainting();
    }

    if (m_activityStateChangeID != ActivityStateChangeAsynchronous || !m_nextActivityStateChangeCallbacks.isEmpty()) {
        m_shouldHandleActivityStateChangeCallbacks = true;
        triggerRenderingUpdate();
    }
}

void TiledCoreAnimationDrawingArea::suspendPainting()
{
    ASSERT(!m_isPaintingSuspended);
    m_isPaintingSuspended = true;

    // This is a signal to media frameworks; it does not actively pause anything.
    [m_hostingLayer setValue:@YES forKey:@"NSCAViewRenderPaused"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSCAViewRenderDidPauseNotification" object:nil userInfo:@{ @"layer": m_hostingLayer.get() }];
}

void TiledCoreAnimationDrawingArea::resumePainting()
{
    if (!m_isPaintingSuspended) {
        // FIXME: We can get a call to resumePainting when painting is not suspended.
        // This happens when sending a synchronous message to create a new page. See <rdar://problem/8976531>.
        return;
    }
    m_isPaintingSuspended = false;

    [m_hostingLayer setValue:@NO forKey:@"NSCAViewRenderPaused"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSCAViewRenderDidResumeNotification" object:nil userInfo:@{ @"layer": m_hostingLayer.get() }];
}

void TiledCoreAnimationDrawingArea::setViewExposedRect(std::optional<FloatRect> viewExposedRect)
{
    m_viewExposedRect = viewExposedRect;

    if (RefPtr frameView = protect(m_webPage)->localMainFrameView())
        frameView->setViewExposedRect(m_viewExposedRect);
}

FloatRect TiledCoreAnimationDrawingArea::exposedContentRect() const
{
    ASSERT_NOT_REACHED();
    return { };
}

void TiledCoreAnimationDrawingArea::setExposedContentRect(const FloatRect&)
{
    ASSERT_NOT_REACHED();
}

void TiledCoreAnimationDrawingArea::updateGeometry(const IntSize& viewSize, bool flushSynchronously, const WTF::MachSendRight& fencePort, CompletionHandler<void()>&& completionHandler)
{
    m_inUpdateGeometry = true;

    IntSize size = viewSize;
    IntSize contentSize = IntSize(-1, -1);

    Ref webPage = m_webPage.get();
    if (!webPage->minimumSizeForAutoLayout().width() || webPage->autoSizingShouldExpandToViewHeight() || (!webPage->sizeToContentAutoSizeMaximumSize().width() && !webPage->sizeToContentAutoSizeMaximumSize().height()))
        webPage->setSize(size);

    RefPtr frameView = webPage->localMainFrameView();

    if (webPage->autoSizingShouldExpandToViewHeight() && frameView)
        frameView->setAutoSizeFixedMinimumHeight(viewSize.height());

    webPage->layoutIfNeeded();

    if (frameView && (webPage->minimumSizeForAutoLayout().width() || (webPage->sizeToContentAutoSizeMaximumSize().width() && webPage->sizeToContentAutoSizeMaximumSize().height()))) {
        contentSize = frameView->autoSizingIntrinsicContentSize();
        size = contentSize;
    }

    updateRendering();

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [m_hostingLayer setFrame:CGRectMake(0, 0, viewSize.width(), viewSize.height())];

    [CATransaction commit];

    if (flushSynchronously)
        [CATransaction flush];

    completionHandler();

    m_inUpdateGeometry = false;

    m_layerHostingContext->setFencePort(fencePort.sendRight());
}

void TiledCoreAnimationDrawingArea::setDeviceScaleFactor(float deviceScaleFactor, CompletionHandler<void()>&& completionHandler)
{
    Ref { m_webPage.get() }->setDeviceScaleFactor(deviceScaleFactor);
    completionHandler();
}

void TiledCoreAnimationDrawingArea::setColorSpace(std::optional<WebCore::DestinationColorSpace> colorSpace)
{
    m_layerHostingContext->setColorSpace(colorSpace ? protect(colorSpace->platformColorSpace()).get() : nullptr);
}

std::optional<WebCore::DestinationColorSpace> TiledCoreAnimationDrawingArea::displayColorSpace() const
{
    return DestinationColorSpace { m_layerHostingContext->colorSpace() };
}

RefPtr<WebCore::DisplayRefreshMonitor> TiledCoreAnimationDrawingArea::createDisplayRefreshMonitor(PlatformDisplayID displayID)
{
    return WebDisplayRefreshMonitor::create(displayID);
}

void TiledCoreAnimationDrawingArea::updateLayerHostingContext()
{
    RetainPtr<CGColorSpaceRef> colorSpace;

    // Invalidate the old context.
    if (m_layerHostingContext) {
        colorSpace = m_layerHostingContext->colorSpace();
        m_layerHostingContext->invalidate();
        m_layerHostingContext = nullptr;
    }

    m_layerHostingContext = LayerHostingContext::create();

    if (m_rootLayer)
        m_layerHostingContext->setRootLayer(m_hostingLayer.get());

    if (colorSpace)
        m_layerHostingContext->setColorSpace(colorSpace.get());
}

void TiledCoreAnimationDrawingArea::setRootCompositingLayer(CALayer *layer)
{
    ASSERT(!m_layerTreeStateIsFrozen);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    bool hadRootLayer = !!m_rootLayer;
    m_rootLayer = layer;

    updateRootLayers();

    if (hadRootLayer != !!layer)
        m_layerHostingContext->setRootLayer(layer ? m_hostingLayer.get() : nil);

    updateDebugInfoLayer(layer && m_webPage->corePage()->settings().showTiledScrollingIndicator());

    [CATransaction commit];
}

void TiledCoreAnimationDrawingArea::updateDebugInfoLayer(bool showLayer)
{
    if (m_debugInfoLayer) {
        [m_debugInfoLayer removeFromSuperlayer];
        m_debugInfoLayer = nil;
    }
    
    if (showLayer) {
        if (CheckedPtr tiledBacking = mainFrameTiledBacking()) {
            if (RefPtr indicatorLayer = tiledBacking->tiledScrollingIndicatorLayer())
                m_debugInfoLayer = indicatorLayer->platformLayer();
        }

        if (m_debugInfoLayer) {
            [m_debugInfoLayer setName:@"Debug Info"];
            [m_hostingLayer addSublayer:m_debugInfoLayer.get()];
        }
    }
}

bool TiledCoreAnimationDrawingArea::shouldUseTiledBackingForFrameView(const LocalFrameView& frameView) const
{
    return frameView.frame().isMainFrame() || m_webPage->corePage()->settings().asyncFrameScrollingEnabled();
}

PlatformCALayer* TiledCoreAnimationDrawingArea::layerForTransientZoom() const
{
    CheckedPtr frameView =  Ref { m_webPage.get() }->localMainFrameView();
    RefPtr scaledLayer = dynamicDowncast<GraphicsLayerCA>(frameView->graphicsLayerForPageScale());
    if (!scaledLayer)
        return nullptr;

    return scaledLayer->platformCALayer();
}

PlatformCALayer* TiledCoreAnimationDrawingArea::shadowLayerForTransientZoom() const
{
    CheckedPtr frameView =  Ref { m_webPage.get() }->localMainFrameView();
    RefPtr shadowLayer = dynamicDowncast<GraphicsLayerCA>(frameView->graphicsLayerForTransientZoomShadow());
    if (!shadowLayer)
        return nullptr;

    return shadowLayer->platformCALayer();
}
    
static FloatPoint shadowLayerPositionForFrame(LocalFrameView& frameView, FloatPoint origin)
{
    // FIXME: correct for b-t documents?
    FloatPoint position = frameView.positionForRootContentLayer();
    return position + origin.expandedTo(FloatPoint());
}

static FloatRect shadowLayerBoundsForFrame(LocalFrameView& frameView, float transientScale)
{
    FloatRect clipLayerFrame(protect(frameView.renderView())->documentRect());
    FloatRect shadowLayerFrame = clipLayerFrame;
    
    shadowLayerFrame.scale(transientScale / frameView.frame().page()->pageScaleFactor());
    shadowLayerFrame.intersect(clipLayerFrame);
    
    return shadowLayerFrame;
}

void TiledCoreAnimationDrawingArea::applyTransientZoomToLayers(double scale, FloatPoint origin)
{
    // FIXME: Scrollbars should stay in-place and change height while zooming.

    if (!m_hostingLayer)
        return;

    RefPtr frameView = protect(m_webPage)->localMainFrameView();
    if (!frameView)
        return;

    TransformationMatrix transform;
    transform.translate(origin.x(), origin.y());
    transform.scale(scale);

    RefPtr zoomLayer = layerForTransientZoom();
    zoomLayer->setTransform(transform);
    zoomLayer->setAnchorPoint(FloatPoint3D());
    zoomLayer->setPosition(FloatPoint3D());
    
    if (RefPtr shadowLayer = shadowLayerForTransientZoom()) {
        shadowLayer->setBounds(shadowLayerBoundsForFrame(*frameView, scale));
        shadowLayer->setPosition(shadowLayerPositionForFrame(*frameView, origin));
    }

    m_transientZoomScale = scale;
    m_transientZoomOrigin = origin;
}

void TiledCoreAnimationDrawingArea::adjustTransientZoom(double scale, FloatPoint origin)
{
    Ref webPage = m_webPage.get();
    scale *= webPage->viewScaleFactor();

    applyTransientZoomToLayers(scale, origin);

    double currentPageScale = webPage->totalScaleFactor();
    if (scale > currentPageScale)
        return;
    prepopulateRectForZoom(scale, origin);
}

void TiledCoreAnimationDrawingArea::commitTransientZoom(double scale, FloatPoint origin, CompletionHandler<void()>&& completionHandler)
{
    Ref webPage = m_webPage.get();
    if (!webPage->localMainFrameView()) {
        completionHandler();
        return;
    }

    scale *= webPage->viewScaleFactor();

    Ref frameView = *webPage->localMainFrameView();
    FloatRect visibleContentRect = frameView->visibleContentRectIncludingScrollbars();

    FloatPoint constrainedOrigin = visibleContentRect.location();
    constrainedOrigin.moveBy(-origin);

    IntSize scaledTotalContentsSize = frameView->totalContentsSize();
    scaledTotalContentsSize.scale(scale / webPage->totalScaleFactor());

    LOG_WITH_STREAM(ViewGestures, stream << "TiledCoreAnimationDrawingArea::commitTransientZoom constrainScrollPositionForOverhang - constrainedOrigin " << constrainedOrigin << " visibleContentRect " << visibleContentRect << " scaledTotalContentsSize " << scaledTotalContentsSize << " scrollOrigin "<< frameView->scrollOrigin() << " headerHeight " << frameView->headerHeight() << " footerHeight " << frameView->footerHeight());

    // Scaling may have exposed the overhang area, so we need to constrain the final
    // layer position exactly like scrolling will once it's committed, to ensure that
    // scrolling doesn't make the view jump.
    constrainedOrigin = ScrollableArea::constrainScrollPositionForOverhang(roundedIntRect(visibleContentRect), scaledTotalContentsSize, roundedIntPoint(constrainedOrigin), frameView->scrollOrigin(), frameView->headerHeight(), frameView->footerHeight());
    constrainedOrigin.moveBy(-visibleContentRect.location());
    constrainedOrigin = -constrainedOrigin;

    LOG_WITH_STREAM(ViewGestures, stream << "TiledCoreAnimationDrawingArea::commitTransientZoom - m_transientZoomScale " << m_transientZoomScale << " scale " << scale << " m_transientZoomOrigin " << m_transientZoomOrigin << " constrainedOrigin " << constrainedOrigin);
    if (m_transientZoomScale == scale && roundedIntPoint(m_transientZoomOrigin) == roundedIntPoint(constrainedOrigin)) {
        // We're already at the right scale and position, so we don't need to animate.
        applyTransientZoomToPage(scale, origin);
        completionHandler();
        return;
    }

    TransformationMatrix transform;
    transform.translate(constrainedOrigin.x(), constrainedOrigin.y());
    transform.scale(scale);

    RetainPtr<CABasicAnimation> renderViewAnimationCA = DrawingArea::transientZoomSnapAnimationForKeyPath("transform"_s);
    auto renderViewAnimation = PlatformCAAnimationCocoa::create(renderViewAnimationCA.get());
    renderViewAnimation->setToValue(transform);

    RetainPtr<CALayer> shadowCALayer;
    if (RefPtr shadowLayer = shadowLayerForTransientZoom())
        shadowCALayer = shadowLayer->platformLayer();

    RefPtr<PlatformCALayer> zoomLayer = layerForTransientZoom();

    [CATransaction begin];
    [CATransaction setCompletionBlock:[zoomLayer, shadowCALayer, webPage, scale, origin] () {
        zoomLayer->removeAnimationForKey("transientZoomCommit"_s);
        if (shadowCALayer)
            [shadowCALayer removeAllAnimations];

        if (RefPtr drawingArea = downcast<TiledCoreAnimationDrawingArea>(webPage->drawingArea()))
            drawingArea->applyTransientZoomToPage(scale, origin);
    }];

    zoomLayer->addAnimationForKey("transientZoomCommit"_s, renderViewAnimation.get());

    if (shadowCALayer) {
        FloatRect shadowBounds = shadowLayerBoundsForFrame(frameView.get(), scale);
        RetainPtr<CGPathRef> shadowPath = adoptCF(CGPathCreateWithRect(shadowBounds, NULL));

        RetainPtr<CABasicAnimation> shadowBoundsAnimation = DrawingArea::transientZoomSnapAnimationForKeyPath("bounds"_s);
        [shadowBoundsAnimation setToValue:[NSValue valueWithRect:shadowBounds]];
        RetainPtr<CABasicAnimation> shadowPositionAnimation = DrawingArea::transientZoomSnapAnimationForKeyPath("position"_s);
        [shadowPositionAnimation setToValue:[NSValue valueWithPoint:shadowLayerPositionForFrame(frameView.get(), constrainedOrigin)]];
        RetainPtr<CABasicAnimation> shadowPathAnimation = DrawingArea::transientZoomSnapAnimationForKeyPath("shadowPath"_s);
        [shadowPathAnimation setToValue:(__bridge id)shadowPath.get()];

        [shadowCALayer addAnimation:shadowBoundsAnimation.get() forKey:@"transientZoomCommitShadowBounds"];
        [shadowCALayer addAnimation:shadowPositionAnimation.get() forKey:@"transientZoomCommitShadowPosition"];
        [shadowCALayer addAnimation:shadowPathAnimation.get() forKey:@"transientZoomCommitShadowPath"];
    }

    [CATransaction commit];
    completionHandler();
}

void TiledCoreAnimationDrawingArea::applyTransientZoomToPage(double scale, FloatPoint origin)
{
    Ref webPage = m_webPage.get();
    if (!webPage->localMainFrameView())
        return;

    // If the page scale is already the target scale, setPageScaleFactor() will short-circuit
    // and not apply the transform, so we can't depend on it to do so.
    TransformationMatrix finalTransform;
    finalTransform.scale(scale);
    protect(layerForTransientZoom())->setTransform(finalTransform);
    
    Ref frameView = *webPage->localMainFrameView();

    if (RefPtr shadowLayer = shadowLayerForTransientZoom()) {
        shadowLayer->setBounds(shadowLayerBoundsForFrame(frameView.get(), 1));
        shadowLayer->setPosition(shadowLayerPositionForFrame(frameView.get(), FloatPoint()));
    }

    FloatPoint unscrolledOrigin(origin);
    FloatRect unobscuredContentRect = frameView->unobscuredContentRectIncludingScrollbars();
    unscrolledOrigin.moveBy(-unobscuredContentRect.location());

    auto scaleOrigin = roundedIntPoint(-unscrolledOrigin);
    webPage->scalePage(scale / webPage->viewScaleFactor(), scaleOrigin);
    m_transientZoomScale = 1;
    updateRendering(UpdateRenderingType::TransientZoom);
}

void TiledCoreAnimationDrawingArea::addFence(const MachSendRight& fencePort)
{
    m_layerHostingContext->setFencePort(fencePort.sendRight());
}

void TiledCoreAnimationDrawingArea::scheduleRenderingUpdateRunLoopObserver()
{
    // 10.9 backport: always wake the main runloop so the observer (which only
    // fires on BeforeWaiting ticks) actually runs. On Mavericks the main thread
    // is dispatch-driven and the CFRunLoop doesn't tick on its own, so without
    // this every kick after the first one is silent.
    CFRunLoopWakeUp(CFRunLoopGetMain());

    if (m_renderingUpdateRunLoopObserver->isScheduled())
        return;

    tracePoint(RenderingUpdateRunLoopObserverStart);

    m_renderingUpdateRunLoopObserver->schedule();

    // 10.9 backport: CFRunLoopObserver BeforeWaiting events don't reliably fire
    // on Mavericks because the WebContent "main thread" is served by libdispatch
    // workers that don't run a true CFRunLoop. Fallback: dispatch_async to main
    // queue so updateRendering runs from a place that does work.
    WeakPtr<TiledCoreAnimationDrawingArea> weakThis { *this };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RefPtr strong = weakThis.get())
            strong->updateRendering();
    });

    // Avoid running any more tasks before the runloop observer fires.
    WebCore::WindowEventLoop::breakToAllowRenderingUpdate();
}

void TiledCoreAnimationDrawingArea::invalidateRenderingUpdateRunLoopObserver()
{
    if (!m_renderingUpdateRunLoopObserver->isScheduled())
        return;

    tracePoint(RenderingUpdateRunLoopObserverEnd, 1);

    m_renderingUpdateRunLoopObserver->invalidate();
}

void TiledCoreAnimationDrawingArea::renderingUpdateRunLoopCallback()
{
    tracePoint(RenderingUpdateRunLoopObserverEnd, 0);

    updateRendering();
}

void TiledCoreAnimationDrawingArea::schedulePostRenderingUpdateRunLoopObserver()
{
    if (m_postRenderingUpdateRunLoopObserver->isScheduled())
        return;

    m_postRenderingUpdateRunLoopObserver->schedule();
}

void TiledCoreAnimationDrawingArea::invalidatePostRenderingUpdateRunLoopObserver()
{
    if (!m_postRenderingUpdateRunLoopObserver->isScheduled())
        return;

    m_postRenderingUpdateRunLoopObserver->invalidate();
}

void TiledCoreAnimationDrawingArea::postRenderingUpdateRunLoopCallback()
{
    didCompleteRenderingFrame();
    invalidatePostRenderingUpdateRunLoopObserver();
}

} // namespace WebKit

#endif // ENABLE(TILED_CA_DRAWING_AREA)
