/*
 * Copyright (C) 2012-2025 Apple Inc. All rights reserved.
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
#import "RemoteLayerTreeDrawingAreaProxy.h"
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/NSAppleScript.h>
#import <atomic>
#import <functional>
#import <unordered_map>

#import "DrawingAreaMessages.h"
#import "DrawingAreaProxyMessages.h"
#import "LayerProperties.h"
#import "Logging.h"
#import "MessageSenderInlines.h"
#import "ProcessThrottler.h"
#import "RemoteLayerTreeCommitBundle.h"
#import "RemoteLayerTreeDrawingAreaProxyMessages.h"
#import "RemotePageDrawingAreaProxy.h"
#import "RemotePageProxy.h"
#import "RemoteScrollingCoordinatorProxy.h"
#import "RemoteScrollingCoordinatorTransaction.h"
#import "RemoteScrollingTreeCocoa.h"
#if PLATFORM(IOS_FAMILY) && ENABLE(OVERLAY_REGIONS_IN_EVENT_REGION)
#import "RemoteScrollingCoordinatorProxyIOS.h"
#endif
#import "WebFrameProxy.h"
#import "WebPageMessages.h"
#import "WebPageProxy.h"
#import "WebProcessProxy.h"
#import "WindowKind.h"
#import <QuartzCore/CATextLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <WebCore/AnimationFrameRate.h>
#import <WebCore/GraphicsContextCG.h>
#import <WebCore/IOSurfacePool.h>
#import <WebCore/ScrollTypes.h>
#import <WebCore/ScrollView.h>
#import <WebCore/WebActionDisablingCALayerDelegate.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/CallbackAggregator.h>
#import <wtf/MachSendRight.h>
#import <wtf/StdLibExtras.h>
#import <wtf/SystemTracing.h>
#import <wtf/TZoneMallocInlines.h>

@interface _WKSlowFrameHUDLayer : CALayer {
    WeakPtr<WebKit::RemoteLayerTreeDrawingAreaProxy> _drawingArea;
}
- (id)initWithDrawingArea:(WebKit::RemoteLayerTreeDrawingAreaProxy*)drawingArea;
@end

@implementation _WKSlowFrameHUDLayer
- (id)initWithDrawingArea:(WebKit::RemoteLayerTreeDrawingAreaProxy*)drawingArea
{
    self = [super init];
    if (!self)
        return nil;
    _drawingArea = drawingArea;
    return self;
}

- (void)drawInContext:(CGContextRef)cgContext
{
    WebCore::GraphicsContextCG context { cgContext, WebCore::GraphicsContextCG::CGContextFromCALayer };
    if (RefPtr drawingArea = _drawingArea.get())
        drawingArea->drawSlowFrameIndicator(context);
}
@end

namespace WebKit {
using namespace IPC;
using namespace WebCore;

static constexpr size_t kSlowFrameIndicatorWidth = 180;
static constexpr size_t kSlowFrameIndicatorHeight = 40;


WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteLayerTreeDrawingAreaProxy);

RemoteLayerTreeDrawingAreaProxy::RemoteLayerTreeDrawingAreaProxy(WebPageProxy& pageProxy, WebProcessProxy& webProcessProxy)
    : DrawingAreaProxy(pageProxy, webProcessProxy)
    , m_remoteLayerTreeHost(makeUnique<RemoteLayerTreeHost>(*this))
    , m_webPageProxyProcessState(webProcessProxy)
{
    // We don't want to pool surfaces in the UI process.
    // FIXME: We should do this somewhere else.
    IOSurfacePool::sharedPoolSingleton().setPoolSize(0);

    if (protect(pageProxy.preferences())->tiledScrollingIndicatorVisible())
        initializeDebugIndicator();

    if (protect(pageProxy.preferences())->slowFrameIndicatorVisible())
        initializeSlowFrameIndicator();
}

RemoteLayerTreeDrawingAreaProxy::~RemoteLayerTreeDrawingAreaProxy() = default;

std::span<IPC::ReceiverName> RemoteLayerTreeDrawingAreaProxy::messageReceiverNames() const
{
    static std::array<IPC::ReceiverName, 2> names { Messages::DrawingAreaProxy::messageReceiverName(), Messages::RemoteLayerTreeDrawingAreaProxy::messageReceiverName() };
    return { names };
}

void RemoteLayerTreeDrawingAreaProxy::addRemotePageDrawingAreaProxy(RemotePageDrawingAreaProxy& proxy)
{
    m_remotePageProcessState.add(proxy.process().coreProcessIdentifier(), ProcessState(proxy.process()));
}

void RemoteLayerTreeDrawingAreaProxy::removeRemotePageDrawingAreaProxy(RemotePageDrawingAreaProxy& proxy)
{
    ASSERT(m_remotePageProcessState.contains(proxy.process().coreProcessIdentifier()));
    m_remotePageProcessState.remove(proxy.process().coreProcessIdentifier());
}

ProcessState::ProcessState(WebProcessProxy& webProcess)
    : nextLayerTreeTransactionID(TransactionID(TransactionIdentifier(), webProcess.coreProcessIdentifier()).next())
{
    pendingCommits.insert(0, { nextLayerTreeTransactionID, PendingCommitMessage::NotifyPendingCommitLayerTree, CommitDelayState::IntentionallyDeferred });
    nextLayerTreeTransactionID.increment();
}

std::unique_ptr<RemoteLayerTreeHost> RemoteLayerTreeDrawingAreaProxy::detachRemoteLayerTreeHost()
{
    m_remoteLayerTreeHost->detachFromDrawingArea();
    return WTF::move(m_remoteLayerTreeHost);
}

void RemoteLayerTreeDrawingAreaProxy::sizeDidChange()
{
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[RLT-Proxy::sizeDidChange] pageID=%llu size=(%d,%d) hasProcess=%d isWaiting=%d\n", this->page() ? (unsigned long long)this->page()->identifier().toUInt64() : 0, size().width(), size().height(), this->page() ? (int)this->page()->hasRunningProcess() : -1, (int)m_isWaitingForDidUpdateGeometry); fclose(_d);}}
    RefPtr page = this->page();
    if (!page || !page->hasRunningProcess())
        return;
    if (CheckedPtr scrollingCoordinator = page->scrollingCoordinatorProxy())
        scrollingCoordinator->viewSizeDidChange();

    if (m_isWaitingForDidUpdateGeometry)
        return;
    sendUpdateGeometry();
}

TransactionID RemoteLayerTreeDrawingAreaProxy::nextMainFrameLayerTreeTransactionID() const
{
    for (int i = m_webPageProxyProcessState.pendingCommits.size() - 1; i >= 0; i--) {
        if (m_webPageProxyProcessState.pendingCommits[i].pendingMessage > PendingCommitMessage::NotifyPendingCommitLayerTree)
            return m_webPageProxyProcessState.pendingCommits[i].transactionID;
    }
    return lastCommittedMainFrameLayerTreeTransactionID();
}

TransactionID RemoteLayerTreeDrawingAreaProxy::lastCommittedMainFrameLayerTreeTransactionID() const
{
    return m_webPageProxyProcessState.committedLayerTreeTransactionID.value_or(TransactionID(TransactionIdentifier(), webProcessProxy().coreProcessIdentifier()));
}

void RemoteLayerTreeDrawingAreaProxy::remotePageProcessDidTerminate(WebCore::ProcessIdentifier processIdentifier)
{
    if (!m_remoteLayerTreeHost)
        return;

    if (CheckedPtr scrollingCoordinator = page() ? page()->scrollingCoordinatorProxy() : nullptr) {
        scrollingCoordinator->willCommitLayerAndScrollingTrees();
        m_remoteLayerTreeHost->remotePageProcessDidTerminate(processIdentifier);
        scrollingCoordinator->didCommitLayerAndScrollingTrees();
    }
}

void RemoteLayerTreeDrawingAreaProxy::viewWillStartLiveResize()
{
    if (CheckedPtr scrollingCoordinator = page() ? page()->scrollingCoordinatorProxy() : nullptr)
        scrollingCoordinator->viewWillStartLiveResize();
}

void RemoteLayerTreeDrawingAreaProxy::viewWillEndLiveResize()
{
    if (CheckedPtr scrollingCoordinator = page() ? page()->scrollingCoordinatorProxy() : nullptr)
        scrollingCoordinator->viewWillEndLiveResize();
}

void RemoteLayerTreeDrawingAreaProxy::deviceScaleFactorDidChange(CompletionHandler<void()>&& completionHandler)
{
    Ref aggregator = CallbackAggregator::create(WTF::move(completionHandler));
    forEachProcessState([&](ProcessState& state, WebProcessProxy& webProcess) {
        if (RefPtr page = this->page())
            webProcess.sendWithAsyncReply(Messages::DrawingArea::SetDeviceScaleFactor(page->deviceScaleFactor()), [aggregator] { }, identifier());
    });
}

void RemoteLayerTreeDrawingAreaProxy::didUpdateGeometry()
{
    ASSERT(m_isWaitingForDidUpdateGeometry);

    m_isWaitingForDidUpdateGeometry = false;

    RefPtr page = this->page();
    if (!page)
        return;

    IntSize minimumSizeForAutoLayout = page->minimumSizeForAutoLayout();
    IntSize sizeToContentAutoSizeMaximumSize = page->sizeToContentAutoSizeMaximumSize();

    // If the WKView was resized while we were waiting for a DidUpdateGeometry reply from the web process,
    // we need to resend the new size here.
    if (m_lastSentSize != size() || m_lastSentMinimumSizeForAutoLayout != minimumSizeForAutoLayout || m_lastSentSizeToContentAutoSizeMaximumSize != sizeToContentAutoSizeMaximumSize)
        sendUpdateGeometry();
}

void RemoteLayerTreeDrawingAreaProxy::sendUpdateGeometry()
{
    RefPtr page = this->page();
    if (!page)
        return;

    m_lastSentMinimumSizeForAutoLayout = page->minimumSizeForAutoLayout();
    m_lastSentSizeToContentAutoSizeMaximumSize = page->sizeToContentAutoSizeMaximumSize();
    m_lastSentSize = size();

    dispatchSetObscuredContentInsets();

    m_isWaitingForDidUpdateGeometry = true;
    sendWithAsyncReply(Messages::DrawingArea::UpdateGeometry(size(), false /* flushSynchronously */, MachSendRight()), [weakThis = WeakPtr { this }] {
        if (!weakThis)
            return;
        weakThis->didUpdateGeometry();
    });
}

ProcessState& RemoteLayerTreeDrawingAreaProxy::processStateForConnection(IPC::Connection& connection)
{
    for (auto& [key, value] : m_remotePageProcessState) {
        RefPtr webProcess = WebProcessProxy::processForIdentifier(key);
        if (webProcess && webProcess->hasConnection(connection))
            return value;
    }

    RELEASE_ASSERT(webProcessProxy().hasConnection(connection));
    return m_webPageProxyProcessState;
}

void RemoteLayerTreeDrawingAreaProxy::forEachProcessState(NOESCAPE Function<void(ProcessState&, WebProcessProxy&)>&& callback)
{
    callback(m_webPageProxyProcessState, webProcessProxy());
    for (auto& [key, value] : m_remotePageProcessState) {
        RefPtr webProcess = WebProcessProxy::processForIdentifier(key);
        if (webProcess)
            callback(value, *webProcess);
    }
}

const ProcessState& RemoteLayerTreeDrawingAreaProxy::processStateForIdentifier(WebCore::ProcessIdentifier identifier) const
{
    if (webProcessProxy().coreProcessIdentifier() == identifier)
        return m_webPageProxyProcessState;

    auto iter = m_remotePageProcessState.find(identifier);
    RELEASE_ASSERT(iter.get());
    return *iter.values();
}

IPC::Connection* RemoteLayerTreeDrawingAreaProxy::connectionForIdentifier(WebCore::ProcessIdentifier processIdentifier)
{
    RefPtr webProcess = WebProcessProxy::processForIdentifier(processIdentifier);
    if (webProcess && webProcess->hasConnection())
        return &webProcess->connection();
    return nullptr;
}

void RemoteLayerTreeDrawingAreaProxy::notifyPendingCommitLayerTree(IPC::Connection& connection, std::optional<TransactionID> transactionID)
{
    ProcessState& state = processStateForConnection(connection);
    LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::notifyPendingCommitLayerTree " << transactionID << " old state: " << state.pendingCommits);
    if (transactionID) {
        if (state.pendingCommits.isEmpty()) {
            // The very first commit is initiated by WebContent, all others get
            // started in response to displayDidRefresh.
            MESSAGE_CHECK_BASE(state.nextLayerTreeTransactionID.object() == TransactionIdentifier().next(), connection);
            MESSAGE_CHECK_BASE(state.nextLayerTreeTransactionID == *transactionID, connection);
            state.pendingCommits.insert(0, { *transactionID, PendingCommitMessage::NotifyFlushingLayerTree, CommitDelayState::Pending });
            state.nextLayerTreeTransactionID = transactionID->next();
        } else {
            MESSAGE_CHECK_BASE(state.pendingCommits[0].pendingMessage == PendingCommitMessage::NotifyPendingCommitLayerTree && state.pendingCommits[0].transactionID == *transactionID, connection);
            state.pendingCommits[0].pendingMessage = PendingCommitMessage::NotifyFlushingLayerTree;
        }
    } else {
        // This frame is still pending, it'll be sent when the WebProcess decides it's ready.
        // Use the IntentionallyDeferred state so that we don't think that it's late
        // when displayDidRefresh arrives.
        MESSAGE_CHECK_BASE(state.pendingCommits.size() && state.pendingCommits[0].pendingMessage == PendingCommitMessage::NotifyPendingCommitLayerTree, connection);
        state.pendingCommits[0].delayState = CommitDelayState::IntentionallyDeferred;

        maybePauseDisplayRefreshCallbacks();

#if ENABLE(ASYNC_SCROLLING)
        if (RefPtr page = this->page())
            protect(page->scrollingCoordinatorProxy())->applyScrollingTreeLayerPositionsAfterCommit();
#endif
    }
}

void RemoteLayerTreeDrawingAreaProxy::notifyFlushingLayerTree(IPC::Connection& connection, TransactionID transactionID)
{
    ProcessState& state = processStateForConnection(connection);
    LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::notifyFlushingLayerTree " << transactionID << " old state: " << state.pendingCommits);

    MESSAGE_CHECK_BASE(state.pendingCommits[0].pendingMessage == PendingCommitMessage::NotifyFlushingLayerTree && state.pendingCommits[0].transactionID == transactionID, connection);
    state.pendingCommits[0].pendingMessage = PendingCommitMessage::CommitLayerTree;

    if (state.canSendDisplayDidRefresh(*this) && state.pendingCommits[0].delayState == CommitDelayState::Delayed) {
        LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::notifyFlushingLayerTree - sending missed didRefreshDisplay");
        didRefreshDisplay(&connection);
    }
}

void RemoteLayerTreeDrawingAreaProxy::commitLayerTree(IPC::Connection& connection, const RemoteLayerTreeCommitBundle& bundle, HashMap<ImageBufferSetIdentifier, std::unique_ptr<BufferSetBackendHandle>>&& handlesMap)
{
    {
        ProcessState& state = processStateForConnection(connection);
        LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree old state: " << state.pendingCommits);
        LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree page data: " << bundle.pageData.description());
        if (bundle.mainFrameData)
            LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree main frame data: " << bundle.mainFrameData->description());
        LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree bundle data: " << bundle.description());
        MESSAGE_CHECK_BASE(state.pendingCommits.size(), connection);
        MESSAGE_CHECK_BASE(state.pendingCommits.last().pendingMessage == PendingCommitMessage::CommitLayerTree, connection);
        MESSAGE_CHECK_BASE(state.pendingCommits.last().transactionID == bundle.transactionID, connection);
        MESSAGE_CHECK_BASE(!state.committedLayerTreeTransactionID || bundle.transactionID == state.committedLayerTreeTransactionID->next(), connection);
    }

    if (bundle.mainFrameData)
        MESSAGE_CHECK_BASE(webProcessProxy().hasConnection(connection), connection);

    // The `sendRights` vector must have __block scope to be captured by
    // the commit handler block below without the need to copy it.
    __block Vector<MachSendRight, 16> sendRights;
    for (auto& transaction : bundle.transactions) {
        // commitLayerTreeTransaction consumes the incoming buffers, so we need to grab them first.
        CheckedRef removeLayerTreeTransaction = transaction.first;
        for (auto& [layerID, properties] : removeLayerTreeTransaction->changedLayerProperties()) {
            auto* backingStoreProperties = properties->backingStoreOrProperties.properties.get();
            if (!backingStoreProperties)
                continue;
            if (backingStoreProperties->bufferSetIdentifier()) {
                auto iter = handlesMap.find(*backingStoreProperties->bufferSetIdentifier());
                if (iter != handlesMap.end())
                    backingStoreProperties->setBackendHandle(*iter->value);
            }
            if (const auto& backendHandle = backingStoreProperties->bufferHandle()) {
                if (const auto* sendRight = std::get_if<MachSendRight>(&backendHandle.value()))
                    sendRights.append(*sendRight);
            }
        }
    }

    PendingCommit completedCommit = [&]() {
        ProcessState& state = processStateForConnection(connection);
        state.committedLayerTreeTransactionID = bundle.transactionID;
        return state.pendingCommits.takeLast();
    }();

    RefPtr page = this->page();
    if (!page)
        return;

    if (bundle.mainFrameData) {
        m_activityStateChangeID = bundle.mainFrameData->activityStateChangeID;

        // FIXME(site-isolation): Editor state should be updated for subframes.
        if (bundle.mainFrameData->editorState && page->updateEditorState(EditorState { *bundle.mainFrameData->editorState }, WebPageProxy::ShouldMergeVisualEditorState::Yes))
            page->dispatchDidUpdateEditorState();

        // Process any callbacks for unhiding content early, so that we
        // set the root node during the same CA transaction.
        for (auto& callbackID : bundle.pageData.callbackIDs) {
            if (callbackID == m_replyForUnhidingContent) {
                RELEASE_LOG(RemoteLayerTree, "RemoteLayerTreeDrawingAreaProxy(%" PRIu64 ")::hideContentUntilPendingUpdate completed", identifier().toUInt64());
                m_replyForUnhidingContent = std::nullopt;
                break;
            }
        }

        page->didCommitMainFrameData(*bundle.mainFrameData, bundle.transactionID);

        if (auto milestones = bundle.mainFrameData->newlyReachedPaintingMilestones)
            page->didReachLayoutMilestone(milestones, WallTime::now());
    }

    WeakPtr weakThis { *this };

    for (auto& transaction : bundle.transactions) {
        commitLayerTreeTransaction(connection, CheckedRef { transaction.first }.get(), transaction.second, bundle.mainFrameData, bundle.pageData, bundle.transactionID);
        if (!weakThis)
            return;
    }

    for (auto& callbackID : bundle.pageData.callbackIDs) {
        removeOutstandingPresentationUpdateCallback(connection, callbackID);
        if (auto callback = connection.takeAsyncReplyHandler(callbackID))
            callback(nullptr, nullptr);
    }

    // Keep IOSurface send rights alive until the transaction is commited, otherwise we will
    // prematurely drop the only reference to them, and `inUse` will be wrong for a brief window.
    // 10.9 backport: +[CATransaction addCommitHandler:forPhase:] is 10.10+. Drop the rights via
    // a runloop dispatch instead. The IOSurface ref-counting still works because the layer
    // already holds the surface as its contents.
    if (!sendRights.isEmpty()) {
        if ([CATransaction respondsToSelector:@selector(addCommitHandler:forPhase:)])
            [CATransaction addCommitHandler:^{ sendRights.clear(); } forPhase:kCATransactionPhasePostCommit];
        else {
            __block auto rightsToRelease = WTF::move(sendRights);
            dispatch_async(dispatch_get_main_queue(), ^{ rightsToRelease.clear(); });
        }
    }

    auto duration = MonotonicTime::now() - bundle.startTime;
    if (duration.value() > (1.0 / displayNominalFramesPerSecond().value_or(FullSpeedFramesPerSecond)))
        WTFEmitSignpost(this, WebKitPerformance, "slowFrame");
    m_frameDurations.append(duration);

    if (m_frameDurations.size() > kSlowFrameIndicatorWidth)
        m_frameDurations.removeFirst();

    {
        ProcessState& state = processStateForConnection(connection);
        if (state.canSendDisplayDidRefresh(*this) && completedCommit.delayState == CommitDelayState::Delayed) {
            LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree - sending missed didRefreshDisplay");
            didRefreshDisplay(&connection);
        } else if (!state.pendingCommits.size()) {
            LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree all pending commits received, waiting for display did refresh");
        }
        if (completedCommit.delayState != CommitDelayState::Delayed && state.delayedCommits)
            state.delayedCommits--;
    }

    updateSlowFrameIndicator();
    scheduleDisplayRefreshCallbacks();

    // 10.9 backport: if the display link isn't running (no displayID assigned because the
    // window isn't backed by a real screen), WebContent never receives DisplayDidRefresh and
    // is stuck waiting after the first commit. Send it after a 150ms delay so WebContent's
    // pending render state has time to settle (immediate dispatch races with the next paint
    // and tends to produce an empty back-buffer commit that overwrites the painted one).
    // Empirical: ~50% success rate at 150ms vs ~20% at 0ms; multi-ping made it worse.
    RunLoop::mainSingleton().dispatchAfter(150_ms, [weakThis = WeakPtr { *this }] {
        if (RefPtr strongThis = weakThis.get())
            strongThis->didRefreshDisplay();
    });
}

#if ENABLE(TOUCH_EVENT_REGIONS)
WebCore::TrackingType RemoteLayerTreeDrawingAreaProxy::eventTrackingTypeForPoint(WebCore::EventTrackingRegions::EventType eventType, IntPoint location)
{
    FloatPoint localLocation = location;
    if (auto* eventRegion = eventRegionForPoint(remoteLayerTreeHost().rootLayer(), localLocation))
        return eventRegion->eventTrackingTypeForPoint(eventType, roundedIntPoint(localLocation));
    return WebCore::TrackingType::NotTracking;
}
#endif

void RemoteLayerTreeDrawingAreaProxy::commitLayerTreeTransaction(IPC::Connection& connection, const RemoteLayerTreeTransaction& layerTreeTransaction, const RemoteScrollingCoordinatorTransaction& scrollingTreeTransaction, const std::optional<MainFrameData>& mainFrameData, const PageData& pageData, const TransactionID& transactionID)
{
    TraceScope tracingScope(CommitLayerTreeStart, CommitLayerTreeEnd);

    LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree transaction:" << layerTreeTransaction.description());
    LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::commitLayerTree scrolling tree:" << scrollingTreeTransaction.description());
    {FILE *_d=((FILE*)0); if(_d){
        CALayer *root = m_remoteLayerTreeHost ? m_remoteLayerTreeHost->rootLayer() : nil;
        fprintf(_d,"[ui-commit] txn id=%llu pageID=%llu root=%p frame=(%f,%f,%f,%f) txnContentsSize=(%f,%f)\n",
            (unsigned long long)transactionID.object().toUInt64(),
            this->page() ? (unsigned long long)this->page()->identifier().toUInt64() : 0,
            root, root.frame.origin.x, root.frame.origin.y, root.frame.size.width, root.frame.size.height,
            layerTreeTransaction.contentsSize().width(), layerTreeTransaction.contentsSize().height());
        fclose(_d);
    }}

    RefPtr page = this->page();
    if (!page)
        return;

    {
        ScrollRequestData requestedScroll;
        CheckedRef scrollingCoordinatorProxy = *page->scrollingCoordinatorProxy();

        auto commitLayerAndScrollingTrees = [&] {
            if (layerTreeTransaction.hasAnyLayerChanges())
                ++m_countOfTransactionsWithNonEmptyLayerChanges;

            bool rootChanged = m_remoteLayerTreeHost->updateLayerTree(connection, layerTreeTransaction, mainFrameData);
            {FILE *_d=((FILE*)0); if(_d){
                CALayer *root = m_remoteLayerTreeHost ? m_remoteLayerTreeHost->rootLayer() : nil;
                fprintf(_d,"[ui-postUpdate] rootChanged=%d rootLayer=%p frame=(%f,%f,%f,%f) sublayers=%lu replyForUnhiding=%d detached=%d\n",
                    (int)rootChanged, root, root.frame.origin.x, root.frame.origin.y, root.frame.size.width, root.frame.size.height,
                    (unsigned long)root.sublayers.count, (int)!!m_replyForUnhidingContent, (int)m_hasDetachedRootLayer);
                fclose(_d);
            }}
            if (rootChanged) {
                if (!m_replyForUnhidingContent) {
                    if (m_hasDetachedRootLayer)
                        RELEASE_LOG(RemoteLayerTree, "RemoteLayerTreeDrawingAreaProxy(%" PRIu64 ") Unhiding layer tree", identifier().toUInt64());
                    auto rootNode = protect(m_remoteLayerTreeHost->rootNode());
                    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[ui-setRootNode] rootNode=%p\n",rootNode.get());fclose(_d);}}
                    page->setRemoteLayerTreeRootNode(rootNode.get());
                    m_hasDetachedRootLayer = false;
                } else
                    m_remoteLayerTreeHost->detachRootLayer();
            }
            requestedScroll = scrollingCoordinatorProxy->commitScrollingTreeState(connection, scrollingTreeTransaction, layerTreeTransaction.remoteContextHostedIdentifier());
        };

        scrollingCoordinatorProxy->willCommitLayerAndScrollingTrees();
        commitLayerAndScrollingTrees();
        scrollingCoordinatorProxy->didCommitLayerAndScrollingTrees();

        page->didCommitLayerTree(layerTreeTransaction, mainFrameData, pageData, transactionID);
        didCommitLayerTree(connection, layerTreeTransaction, scrollingTreeTransaction, mainFrameData, transactionID);

        scrollingCoordinatorProxy->applyScrollingTreeLayerPositionsAfterCommit();
#if PLATFORM(IOS_FAMILY)
        page->adjustLayersForLayoutViewport(page->unobscuredContentRect().location(), page->unconstrainedLayoutViewportRect(), page->displayedContentScale());
#endif
        // Handle requested scroll position updates from the scrolling tree transaction after didCommitLayerTree()
        // has updated the view size based on the content size.
        if (requestedScroll.size())
            scrollingCoordinatorProxy->adjustMainFrameDelegatedScrollPosition(WTF::move(requestedScroll));

#if ENABLE(OVERLAY_REGIONS_IN_EVENT_REGION)
        if (layerTreeTransaction.changedLayerProperties().size() || layerTreeTransaction.destroyedLayers().size())
            scrollingCoordinatorProxy->updateOverlayRegions(layerTreeTransaction.destroyedLayers());
#endif

        if (m_debugIndicatorLayerTreeHost && mainFrameData) {
            float scale = indicatorScale(layerTreeTransaction.contentsSize());
            scrollingCoordinatorProxy->willCommitLayerAndScrollingTrees();
            bool rootLayerChanged = m_debugIndicatorLayerTreeHost->updateLayerTree(connection, layerTreeTransaction, mainFrameData, scale);
            scrollingCoordinatorProxy->didCommitLayerAndScrollingTrees();
            IntPoint scrollPosition;
#if PLATFORM(MAC)
            scrollPosition = layerTreeTransaction.scrollPosition();
#endif
            updateDebugIndicator(layerTreeTransaction.contentsSize(), rootLayerChanged, scale, scrollPosition);
            protect(m_debugIndicatorLayerTreeHost->rootLayer()).get().name = @"Indicator host root";
        }
    }

    page->layerTreeCommitComplete();
    [CATransaction flush];

    // 10.9 backport: WebKit creates "transform passthrough" CALayers with
    // bounds=0x0 anchor=(0.5,0.5) — they're meant to compose sublayers directly
    // without contributing geometry. Modern macOS CA composes their sublayers
    // anyway; on 10.9 these zero-bounds layers cull their entire subtree from
    // composition. Original fix: set bounds to 16384x16384.
    //
    // 2026-05-17 perf: the 16384x16384 bounds expansion was causing severe
    // input lag (user reported scrolling/selection/hover all delayed multi-
    // second). Hypothesis: a 16384^2 CALayer's backing store / dirty-region
    // tracking is huge even when it has no contents — every layer commit
    // touches enormous regions. Try the lighter-weight approach: set
    // masksToBounds=NO (default) and leave bounds=0. Sublayers should still
    // composite because CALayer doesn't actually cull on zero bounds when
    // masksToBounds is false — the original cull was likely caused by some
    // OTHER code setting masksToBounds=YES somewhere. If sublayers still
    // don't paint, we'll need a different fix (e.g., set the layer's
    // backgroundColor to nil + cornerRadius=0 + force compositing).
    if (m_remoteLayerTreeHost) {
        if (auto root = m_remoteLayerTreeHost->rootNode()) {
            CALayer *rl = root->layer();
            std::function<void(CALayer*)> fixPassthrough = [&](CALayer *layer) {
                if ([[layer valueForKey:@"_wk_109_fixed"] boolValue]) {
                    for (CALayer *sl in [layer sublayers])
                        fixPassthrough(sl);
                    return;
                }
                CGRect b = [layer bounds];
                if ((b.size.width == 0 || b.size.height == 0) && [[layer sublayers] count] > 0) {
                    [layer setMasksToBounds:NO];
                    // Don't expand bounds — leave at 0. CA composites sublayers
                    // when parent's masksToBounds is NO regardless of parent bounds.
                }
                [layer setValue:@YES forKey:@"_wk_109_fixed"];
                for (CALayer *sl in [layer sublayers])
                    fixPassthrough(sl);
            };
            fixPassthrough(rl);
        }
    }

    // 10.9 diagnostic: dump root layer tree state to /tmp/load_dbg.log
    // (disabled by default for perf; set to true to re-enable)
    static const bool kDiagDump = false;
    if (kDiagDump && m_remoteLayerTreeHost) {
        if (auto root = m_remoteLayerTreeHost->rootNode()) {
            CALayer *rl = root->layer();
            CALayer *container = [rl superlayer];
            static unsigned s_diagCount = 0;
            FILE *_d = (s_diagCount++ < 5) ? ((FILE*)0) : ((FILE*)0);
            if (_d && rl) {
                fprintf(_d, "[diag PID %d] rl=%p class=%s frame=(%g,%g,%gx%g) bounds=(%g,%g,%gx%g) hidden=%d masksToBounds=%d opacity=%g sublayers=%lu container=%p\n",
                    getpid(), rl, object_getClassName(rl),
                    (double)[rl frame].origin.x, (double)[rl frame].origin.y,
                    (double)[rl frame].size.width, (double)[rl frame].size.height,
                    (double)[rl bounds].origin.x, (double)[rl bounds].origin.y,
                    (double)[rl bounds].size.width, (double)[rl bounds].size.height,
                    (int)[rl isHidden], (int)[rl masksToBounds], (double)[rl opacity],
                    (unsigned long)[[rl sublayers] count], container);
                if (container) {
                    fprintf(_d, "  container=%p class=%s frame=(%g,%g,%gx%g) bounds=(%g,%g,%gx%g) hidden=%d masksToBounds=%d opacity=%g geomFlipped=%d\n",
                        container, object_getClassName(container),
                        (double)[container frame].origin.x, (double)[container frame].origin.y,
                        (double)[container frame].size.width, (double)[container frame].size.height,
                        (double)[container bounds].origin.x, (double)[container bounds].origin.y,
                        (double)[container bounds].size.width, (double)[container bounds].size.height,
                        (int)[container isHidden], (int)[container masksToBounds], (double)[container opacity],
                        (int)[container isGeometryFlipped]);
                }
                std::function<void(CALayer*, int, int)> dumpRec = [&](CALayer *sl, int depth, int idx) {
                    CATransform3D t = [sl transform];
                    auto* node = RemoteLayerTreeNode::forCALayer(sl);
                    uint64_t lid = node ? node->layerID().object().toUInt64() : 0;
                    fprintf(_d, "  %*ssub[%d]=%p lid=%llu class=%s frame=(%g,%g,%gx%g) bounds=(%g,%g,%gx%g) hidden=%d opacity=%g contents=%p subs=%lu pos=(%g,%g) anchor=(%g,%g) T=[m11=%g m22=%g m41=%g m42=%g]\n",
                        depth*2, "", idx, sl, (unsigned long long)lid, object_getClassName(sl),
                        (double)[sl frame].origin.x, (double)[sl frame].origin.y,
                        (double)[sl frame].size.width, (double)[sl frame].size.height,
                        (double)[sl bounds].origin.x, (double)[sl bounds].origin.y,
                        (double)[sl bounds].size.width, (double)[sl bounds].size.height,
                        (int)[sl isHidden], (double)[sl opacity], [sl contents],
                        (unsigned long)[[sl sublayers] count],
                        (double)[sl position].x, (double)[sl position].y,
                        (double)[sl anchorPoint].x, (double)[sl anchorPoint].y,
                        t.m11, t.m22, t.m41, t.m42);
                    if (depth < 8) {
                        int ci = 0;
                        for (CALayer *c in [sl sublayers]) {
                            dumpRec(c, depth + 1, ci++);
                            if (ci >= 12) break;
                        }
                    }
                };
                int idx = 0;
                for (CALayer *sl in [rl sublayers]) {
                    dumpRec(sl, 1, idx++);
                    if (idx >= 5) break;
                }
                fclose(_d);
            }
        }
    }
}

void RemoteLayerTreeDrawingAreaProxy::remirrorFor10_9()
{
    if (!m_remoteLayerTreeHost) return;
    // 10.9 backport: rootNode->layer() refuses to compose its sublayers on Mavericks
    // (extensively verified). As a workaround, walk the WebKit tree and emit a fresh
    // plain-CALayer mirror for every layer that has .contents set, attached directly
    // to our compositing container at the layer's absolute position within the root.
    //
    // Additional 10.9 fallback: also walk all nodes in m_remoteLayerTreeHost->m_nodes.
    // Github navigations don't propagate the wrapper layer's children property update,
    // so github's tile layers (with painted content) never become children of the visible
    // root. By walking m_nodes directly we can still find those tile-bearing layers.
    if (auto root = m_remoteLayerTreeHost->rootNode()) {
        CALayer *rl = root->layer();
        CALayer *container = [rl superlayer]; // The wrapper container we attached.
        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[mirror-walk PID %d] rl=%p container=%p\n", getpid(), rl, container); fclose(_d);}}
        if (rl && container) {
            // 10.9 backport: defer removing existing mirrors until we know we have
            // new content. On cold loads with intermittent layer commits, an
            // earlier remirror may have emitted real mirrors but a later one finds
            // no qualifying tile content (e.g. m_nodes only has empty placeholders
            // at this instant). Removing then re-adding nothing destroys the
            // visible render. We collect new mirrors into a temp array and only
            // swap if the new set is non-empty.
            // 10.9 backport: rl-tree walk DISABLED. It emits whatever in-progress
            // layers exist at this moment, including sidebar items and README
            // content from non-final layouts. The m_nodes "extras" walk below
            // (with size + position filter + layerID dedup) gives a stable set.
            #if 0
            // Walk rl's tree, accumulating absolute positions in rl's coordinate space.
            // Container is geometryFlipped:YES, so y grows downward inside container.
            // rl is at (0,0) within container (top-left).
            NSMutableArray *stack = [NSMutableArray arrayWithObject:@[rl, [NSValue valueWithPoint:NSMakePoint(0, 0)]]];
            while ([stack count] > 0) {
                NSArray *e = [stack lastObject]; [stack removeLastObject];
                CALayer *x = e[0];
                NSPoint accum = [e[1] pointValue];
                // For each sublayer, its absolute position inside rl is accum + sublayer.frame.origin.
                for (CALayer *c in [x sublayers]) {
                    CGRect f = [c frame];
                    NSPoint childAbs = NSMakePoint(accum.x + f.origin.x, accum.y + f.origin.y);
                    // 10.9 backport: CATransformLayer doesn't implement contents/setContents.
                    if (![c respondsToSelector:@selector(contents)]) {
                        [stack addObject:@[c, [NSValue valueWithPoint:childAbs]]];
                        continue;
                    }
                    if ([c contents]) {
                        {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[mirror PID %d] emit for layer=%p contents=%p frame=(%g,%g,%gx%g) abs=(%g,%g)\n", getpid(), c, [c contents], (double)f.origin.x, (double)f.origin.y, (double)f.size.width, (double)f.size.height, (double)childAbs.x, (double)childAbs.y); fclose(_d);}}

                        CALayer *m = [CALayer layer];
                        [m setName:@"__10_9_mirror__"];
                        [m setContents:[c contents]];
                        if ([c contentsGravity])
                            [m setContentsGravity:[c contentsGravity]];
                        [m setContentsScale:[c contentsScale]];
                        [m setContentsRect:[c contentsRect]];
                        [m setOpaque:[c isOpaque]];
                        [m setAnchorPoint:CGPointMake(0, 0)];
                        [m setPosition:CGPointMake(childAbs.x, childAbs.y)];
                        [m setBounds:CGRectMake(0, 0, f.size.width, f.size.height)];
                        [m setZPosition:1];
                        [container addSublayer:m];
                    }
                    [stack addObject:@[c, [NSValue valueWithPoint:childAbs]]];
                }
            }
            #endif

            // 10.9 backport: also walk all m_nodes, mirror any tile-bearing layers
            // not already mirrored above. Position from the layer's CALayer.position
            // (we don't have the parent chain here, so just trust the layer's own
            // position in its parent's coordinate system).
            //
            // 10.9 NOTE: filter to ONLY tile-backing layers (>= 256 in both dims).
            // Smaller layers represent UI elements (text rows, dropdown buttons) whose
            // positions in m_nodes don't reflect the composited layout (they have
            // negative x/y from un-resolved transforms). Mirroring them produces visual
            // chaos — overlapping content on the left edge from sidebar items.
            //
            // 10.9 backport: TWO-PASS to dedup by position bucket. m_nodes accumulates
            // ALL tile layers ever created. Old blank tile IDs (e.g. 22-28) and new
            // content tile IDs (e.g. 884+) often share the same screen position. Without
            // dedup, addSublayer order (= hashmap iteration order) determines who wins,
            // and old blank tiles often win randomly. With dedup, the highest layer ID
            // (= most recently created = most likely to have content) wins per bucket.
            std::unordered_map<uint64_t, uint64_t> bucketWinner;
            auto bucketKeyFor = [](CGRect f) -> uint64_t {
                uint16_t x = (uint16_t)(int)f.origin.x;
                uint16_t y = (uint16_t)(int)f.origin.y;
                uint16_t w = (uint16_t)(int)f.size.width;
                uint16_t h = (uint16_t)(int)f.size.height;
                return ((uint64_t)x << 48) | ((uint64_t)y << 32) | ((uint64_t)w << 16) | (uint64_t)h;
            };
            // 10.9 backport: only emit layers whose frame origin is RELIABLE for
            // direct positioning in container. CALayer.frame is in PARENT coordinate
            // system. If the parent has a non-zero position/transform, the child's
            // frame doesn't reflect screen coordinates. Filter to layers where superlayer
            // is the root (rl) or has frame.origin == (0,0) — i.e. layers whose absolute
            // position equals their own frame.origin.
            auto canTrustFramePosition = [&](CALayer *c) -> bool {
                CALayer *p = [c superlayer];
                while (p && p != rl) {
                    CGRect pf = [p frame];
                    if (pf.origin.x != 0 || pf.origin.y != 0) return false;
                    p = [p superlayer];
                }
                return p != nil; // must reach rl
            };
            // Pass 1: find max layerID per bucket.
            for (auto& [layerID, node] : m_remoteLayerTreeHost->allNodesFor10_9()) {
                CALayer *c = node->layer();
                if (!c) continue;
                if (![c respondsToSelector:@selector(contents)]) continue;
                if (![c contents]) continue;
                CGRect f = [c frame];
                if (f.size.width < 16 || f.size.height < 16) continue;
                if (f.origin.x < 0 || f.origin.y < 0) continue;
                if (!canTrustFramePosition(c)) continue;
                uint64_t key = bucketKeyFor(f);
                uint64_t lid = layerID.object().toUInt64();
                auto it = bucketWinner.find(key);
                if (it == bucketWinner.end() || lid > it->second)
                    bucketWinner[key] = lid;
            }
            // Pass 2: build new mirrors into a temp array first.
            NSMutableArray *newMirrors = [NSMutableArray array];
            int extras = 0;
            for (auto& [layerID, node] : m_remoteLayerTreeHost->allNodesFor10_9()) {
                CALayer *c = node->layer();
                if (!c) continue;
                if (![c respondsToSelector:@selector(contents)]) continue;
                if (![c contents]) continue;
                CGRect f = [c frame];
                if (f.size.width < 16 || f.size.height < 16) continue;
                if (f.origin.x < 0 || f.origin.y < 0) continue;
                if (!canTrustFramePosition(c)) continue;
                uint64_t key = bucketKeyFor(f);
                uint64_t lid = layerID.object().toUInt64();
                auto it = bucketWinner.find(key);
                if (it == bucketWinner.end() || it->second != lid) continue;
                // 10.9 diag: dump first 4 unique tile contents to /tmp/uiproc_tile_layerNN.png
                // so we can verify whether tiles carry real pixels.
                static int s_dumpCount = 0;
                if (s_dumpCount < 30) {
                    CFTypeRef raw = (__bridge CFTypeRef)[c contents];
                    if (raw && CFGetTypeID(raw) == CGImageGetTypeID()) {
                        s_dumpCount++;
                        char path[128];
                        snprintf(path, sizeof(path), "/tmp/uiproc_tile_layer%llu_%d.png", (unsigned long long)layerID.object().toUInt64(), s_dumpCount);
                        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path, strlen(path), false);
                        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);
                        if (dst) {
                            CGImageDestinationAddImage(dst, (CGImageRef)raw, NULL);
                            CGImageDestinationFinalize(dst);
                            CFRelease(dst);
                        }
                        CFRelease(url);
                        FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[uiproc-dump PID %d] dumped %s w=%zu h=%zu\n", getpid(), path, CGImageGetWidth((CGImageRef)raw), CGImageGetHeight((CGImageRef)raw)); fclose(_d);}
                    }
                }
                // Compute absolute position by walking up the CALayer tree to find ancestor coordinates.
                // For now use the layer's own position in screen space — which for tiles is just their frame origin.
                // This won't be perfect for nested compositing but should put tiles roughly correctly.
                NSPoint abs = NSMakePoint(f.origin.x, f.origin.y);
                CALayer *m = [CALayer layer];
                [m setName:@"__10_9_mirror__"];
                [m setContents:[c contents]];
                if ([c contentsGravity])
                    [m setContentsGravity:[c contentsGravity]];
                [m setContentsScale:[c contentsScale]];
                [m setContentsRect:[c contentsRect]];
                [m setOpaque:[c isOpaque]];
                [m setAnchorPoint:CGPointMake(0, 0)];
                [m setPosition:CGPointMake(abs.x, abs.y)];
                [m setBounds:CGRectMake(0, 0, f.size.width, f.size.height)];
                // 10.9 backport: full-width SHORT layers (e.g. github's 1009x67
                // dark header) get a higher zPosition so they composite ABOVE
                // square viewport tiles at the same screen position.
                if (f.size.width >= 800 && f.size.height < 200)
                    [m setZPosition:3];
                else
                    [m setZPosition:2];
                [newMirrors addObject:m];
                ++extras;
                if (extras < 8) {
                    FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[mirror-extra PID %d] layerID=%llu c=%p contents=%p frame=(%g,%g,%gx%g)\n",
                        getpid(), (unsigned long long)layerID.object().toUInt64(), c, [c contents], (double)f.origin.x, (double)f.origin.y, (double)f.size.width, (double)f.size.height); fclose(_d);}
                }
            }
            // 10.9 backport: only swap the mirror set if we have new content.
            // If extras == 0 (transient blank state), leave the previous good
            // mirrors in place so the visible render isn't destroyed.
            if (extras > 0) {
                {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[mirror-extra PID %d] total extras=%d, swapping mirrors\n", getpid(), extras); fclose(_d);}}
                NSArray *exist = [[container sublayers] copy];
                for (CALayer *sl in exist) {
                    if ([[sl name] isEqualToString:@"__10_9_mirror__"])
                        [sl removeFromSuperlayer];
                }
                for (CALayer *m in newMirrors)
                    [container addSublayer:m];
                // 10.9 backport: force the host CALayer / NSWindow to redraw so that
                // freshly-added mirror sublayers actually become visible. Without this,
                // initial-load mirrors are added to the layer tree but the host doesn't
                // composite them until the user scrolls/clicks.
                CALayer *walk = container;
                while (walk) {
                    id delegate = [walk delegate];
                    if (delegate && [delegate respondsToSelector:@selector(setNeedsDisplay:)]) {
                        [delegate performSelector:@selector(setNeedsDisplay:) withObject:@YES];
                        break;
                    }
                    walk = [walk superlayer];
                }
            }

        }
    }

    // 10.9 backport: diagnose by dumping transforms and sublayerTransforms so we can
    // see if an ancestor is collapsing the subtree.
    if (auto root = m_remoteLayerTreeHost->rootNode()) {
        CALayer *rl = root->layer();
        if (rl) {
            FILE *_d=((FILE*)0);
            if (_d) {
                fprintf(_d, "[xform-dump PID %d] root=%p\n", getpid(), rl);
                NSMutableArray *stack = [NSMutableArray array];
                for (CALayer *s in [rl sublayers]) [stack addObject:@[s, @1]];
                while ([stack count] > 0) {
                    NSArray *e = [stack lastObject]; [stack removeLastObject];
                    CALayer *sl = e[0]; int d = [e[1] intValue];
                    CATransform3D t = [sl transform];
                    CATransform3D st = [sl sublayerTransform];
                    fprintf(_d, "  d=%d %p T=[%g %g %g %g; %g %g %g %g; %g %g %g %g; %g %g %g %g] sT=[%g %g %g %g; %g %g %g %g; %g %g %g %g; %g %g %g %g]\n",
                        d, sl,
                        t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24,
                        t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44,
                        st.m11, st.m12, st.m13, st.m14, st.m21, st.m22, st.m23, st.m24,
                        st.m31, st.m32, st.m33, st.m34, st.m41, st.m42, st.m43, st.m44);
                    if (d < 8)
                        for (CALayer *c in [sl sublayers]) [stack addObject:@[c, @(d+1)]];
                }
                fclose(_d);
            }
        }
    }

    // 10.9 diag: dump rootNode's tree after commit
    if (auto root = m_remoteLayerTreeHost->rootNode()) {
        CALayer *rl = root->layer();
        FILE *_d=((FILE*)0);
        if (_d && rl) {
            fprintf(_d, "[post-commit PID %d] drawingArea=%p root=%p sublayers=%lu bounds=%gx%g\n",
                getpid(), this, rl, (unsigned long)[[rl sublayers] count],
                (double)[rl bounds].size.width, (double)[rl bounds].size.height);
            NSMutableArray *stack = [NSMutableArray array];
            for (CALayer *s in [rl sublayers]) [stack addObject:@[s, @1]];
            while ([stack count] > 0) {
                NSArray *e = [stack lastObject]; [stack removeLastObject];
                CALayer *sl = e[0]; int d = [e[1] intValue];
                fprintf(_d, "  %*s[d=%d] %p frame=(%g,%g,%gx%g) contents=%p subs=%lu contentsScale=%g contentsGravity=%s contentsRect=(%g,%g,%gx%g) opaque=%d\n",
                    d*2, "", d, sl,
                    (double)[sl frame].origin.x, (double)[sl frame].origin.y,
                    (double)[sl frame].size.width, (double)[sl frame].size.height,
                    [sl contents], (unsigned long)[[sl sublayers] count],
                    (double)[sl contentsScale], [[sl contentsGravity] UTF8String] ?: "<nil>",
                    (double)[sl contentsRect].origin.x, (double)[sl contentsRect].origin.y,
                    (double)[sl contentsRect].size.width, (double)[sl contentsRect].size.height,
                    (int)[sl isOpaque]);
                if (d < 8)
                    for (CALayer *ss in [sl sublayers]) [stack addObject:@[ss, @(d+1)]];
            }
            fclose(_d);
        }
    }
}

void RemoteLayerTreeDrawingAreaProxy::asyncSetLayerContents(WebCore::PlatformLayerIdentifier layerID, RemoteLayerBackingStoreProperties&& properties)
{
    m_remoteLayerTreeHost->asyncSetLayerContents(layerID, WTF::move(properties));
}

void RemoteLayerTreeDrawingAreaProxy::acceleratedAnimationDidStart(WebCore::PlatformLayerIdentifier layerID, const String& key, MonotonicTime startTime)
{
    if (RefPtr connection = connectionForIdentifier(layerID.processIdentifier()))
        connection->send(Messages::DrawingArea::AcceleratedAnimationDidStart(layerID, key, startTime), identifier());
}

void RemoteLayerTreeDrawingAreaProxy::acceleratedAnimationDidEnd(WebCore::PlatformLayerIdentifier layerID, const String& key)
{
    if (RefPtr connection = connectionForIdentifier(layerID.processIdentifier()))
        connection->send(Messages::DrawingArea::AcceleratedAnimationDidEnd(layerID, key), identifier());
}

static const float indicatorInset = 10;

FloatPoint RemoteLayerTreeDrawingAreaProxy::indicatorLocation() const
{
    FloatPoint tiledMapLocation;
    RefPtr page = this->page();
    if (!page)
        return { };

#if PLATFORM(IOS_FAMILY)
    tiledMapLocation = page->unobscuredContentRect().location().expandedTo(FloatPoint());
    tiledMapLocation = tiledMapLocation.expandedTo(page->exposedContentRect().location());

    float absoluteInset = indicatorInset / page->displayedContentScale();
    tiledMapLocation += FloatSize(absoluteInset, absoluteInset);
#else
    tiledMapLocation = FloatPoint(page->obscuredContentInsets().left(), page->obscuredContentInsets().top());

    tiledMapLocation += FloatSize(indicatorInset, indicatorInset);
    float scale = 1 / page->pageScaleFactor();
    tiledMapLocation.scale(scale);
#endif
    return tiledMapLocation;
}

void RemoteLayerTreeDrawingAreaProxy::updateDebugIndicatorPosition()
{
    if (m_slowFrameIndicatorLayer)
        [m_slowFrameIndicatorLayer setPosition:indicatorLocation()];

    if (!m_tileMapHostLayer)
        return;

    [m_tileMapHostLayer setPosition:indicatorLocation()];
}

float RemoteLayerTreeDrawingAreaProxy::indicatorScale(IntSize contentsSize) const
{
    // Pick a good scale.
    RefPtr page = this->page();
    if (!page)
        return 1;

    IntSize viewSize = page->viewSize();

    float scale = 1;
    if (!contentsSize.isEmpty()) {
        float widthScale = std::min<float>((viewSize.width() - 2 * indicatorInset) / contentsSize.width(), 0.05);
        scale = std::min(widthScale, static_cast<float>(viewSize.height() - 2 * indicatorInset) / contentsSize.height());
    }
    
    return scale;
}

void RemoteLayerTreeDrawingAreaProxy::updateDebugIndicator()
{
    // FIXME: we should also update live information during scale.
    updateDebugIndicatorPosition();
}

void RemoteLayerTreeDrawingAreaProxy::updateDebugIndicator(IntSize contentsSize, bool rootLayerChanged, float scale, const IntPoint& scrollPosition)
{
    // Make sure we're the last sublayer.
    RetainPtr rootLayer = m_remoteLayerTreeHost->rootLayer();
    [m_tileMapHostLayer removeFromSuperlayer];
    [rootLayer addSublayer:m_tileMapHostLayer.get()];

    [m_tileMapHostLayer setBounds:FloatRect(FloatPoint(), contentsSize)];
    [m_tileMapHostLayer setPosition:indicatorLocation()];
    [m_tileMapHostLayer setTransform:CATransform3DMakeScale(scale, scale, 1)];

    if (rootLayerChanged) {
        [m_tileMapHostLayer setSublayers:@[]];
        [m_tileMapHostLayer addSublayer:protect(m_debugIndicatorLayerTreeHost->rootLayer()).get()];
        [m_tileMapHostLayer addSublayer:m_exposedRectIndicatorLayer.get()];
    }
    
    const float indicatorBorderWidth = 1;
    float counterScaledBorder = indicatorBorderWidth / scale;

    [m_exposedRectIndicatorLayer setBorderWidth:counterScaledBorder];

    FloatRect scaledExposedRect;
    RefPtr page = this->page();
    if (!page)
        return;

#if PLATFORM(IOS_FAMILY)
    scaledExposedRect = page->exposedContentRect();
#else
    if (auto viewExposedRect = page->viewExposedRect())
        scaledExposedRect = *viewExposedRect;
    float counterScale = 1 / page->pageScaleFactor();
    scaledExposedRect.scale(counterScale);
#endif
    [m_exposedRectIndicatorLayer setPosition:scaledExposedRect.location()];
    [m_exposedRectIndicatorLayer setBounds:FloatRect(FloatPoint(), scaledExposedRect.size())];
}

void RemoteLayerTreeDrawingAreaProxy::initializeDebugIndicator()
{
    m_debugIndicatorLayerTreeHost = makeUnique<RemoteLayerTreeHost>(*this);
    m_debugIndicatorLayerTreeHost->setIsDebugLayerTreeHost(true);

    m_tileMapHostLayer = adoptNS([[CALayer alloc] init]);
    [m_tileMapHostLayer setName:@"Tile map host"];
    [m_tileMapHostLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
    [m_tileMapHostLayer setAnchorPoint:CGPointZero];
    [m_tileMapHostLayer setOpacity:0.8];
    [m_tileMapHostLayer setMasksToBounds:YES];
    [m_tileMapHostLayer setBorderWidth:2];

    RetainPtr colorSpace = sRGBColorSpaceSingleton();
    {
        const CGFloat components[] = { 1, 1, 1, 0.6 };
        RetainPtr<CGColorRef> color = adoptCF(CGColorCreate(colorSpace.get(), components));
        [m_tileMapHostLayer setBackgroundColor:color.get()];

        const CGFloat borderComponents[] = { 0, 0, 0, 1 };
        RetainPtr<CGColorRef> borderColor = adoptCF(CGColorCreate(colorSpace.get(), borderComponents));
        [m_tileMapHostLayer setBorderColor:borderColor.get()];
    }
    
    m_exposedRectIndicatorLayer = adoptNS([[CALayer alloc] init]);
    [m_exposedRectIndicatorLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
    [m_exposedRectIndicatorLayer setAnchorPoint:CGPointZero];

    {
        const CGFloat components[] = { 0, 1, 0, 1 };
        RetainPtr<CGColorRef> color = adoptCF(CGColorCreate(colorSpace.get(), components));
        [m_exposedRectIndicatorLayer setBorderColor:color.get()];
    }
}

void RemoteLayerTreeDrawingAreaProxy::initializeSlowFrameIndicator()
{
    m_slowFrameIndicatorLayer= adoptNS([[_WKSlowFrameHUDLayer alloc] initWithDrawingArea:this]);
    [m_slowFrameIndicatorLayer setName:@"Slow frame indicator"];
    [m_slowFrameIndicatorLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
    [m_slowFrameIndicatorLayer setAnchorPoint:CGPointZero];
    [m_slowFrameIndicatorLayer setPosition:indicatorLocation()];
    [m_slowFrameIndicatorLayer setBounds:FloatRect(FloatPoint(), FloatSize(kSlowFrameIndicatorWidth, kSlowFrameIndicatorHeight))];
    RetainPtr backgroundColor = adoptCF(CGColorCreateCopyWithAlpha(RetainPtr { CGColorGetConstantColor(kCGColorBlack) }.get(), 0.1));
    [m_slowFrameIndicatorLayer setBackgroundColor:backgroundColor.get()];
}

void RemoteLayerTreeDrawingAreaProxy::updateSlowFrameIndicator()
{
    if (!m_slowFrameIndicatorLayer)
        return;

    // Make sure we're the last sublayer.
    [m_slowFrameIndicatorLayer removeFromSuperlayer];
    RetainPtr rootLayer = m_remoteLayerTreeHost->rootLayer();
    [rootLayer addSublayer:m_slowFrameIndicatorLayer.get()];

    [m_slowFrameIndicatorLayer setNeedsDisplay];
}

void RemoteLayerTreeDrawingAreaProxy::drawSlowFrameIndicator(WebCore::GraphicsContext& context)
{
    context.clearRect(FloatRect(0, 0, kSlowFrameIndicatorWidth, kSlowFrameIndicatorHeight));

    size_t index = kSlowFrameIndicatorWidth - m_frameDurations.size();
    for (auto duration : m_frameDurations) {
        float frameintervals = duration.value() / (1.0 / displayNominalFramesPerSecond().value_or(FullSpeedFramesPerSecond));
        bool slow = frameintervals > 1.0;

        size_t height = std::round(frameintervals * 10);
        height = std::min(kSlowFrameIndicatorHeight, height);

        context.setFillColor(slow ? Color(Color::red) : Color(Color::green).colorWithAlpha(0.5));
        context.fillRect(FloatRect(index, kSlowFrameIndicatorHeight - height, 1, height));
        index++;
    }
}

bool RemoteLayerTreeDrawingAreaProxy::maybePauseDisplayRefreshCallbacks()
{
    if (!m_webPageProxyProcessState.pendingCommits.size() || m_webPageProxyProcessState.pendingCommits[0].delayState != CommitDelayState::IntentionallyDeferred)
        return false;

    for (auto& pair : m_remotePageProcessState) {
        if (!pair.value.pendingCommits.size() || pair.value.pendingCommits[0].delayState != CommitDelayState::IntentionallyDeferred)
            return false;
    }

    pauseDisplayRefreshCallbacks();
    return true;
}

void RemoteLayerTreeDrawingAreaProxy::didRefreshDisplay()
{
    didRefreshDisplay(nullptr);
}

TextStream& operator<<(TextStream& ts, const PendingCommitMessage& state)
{
    if (state == PendingCommitMessage::NotifyPendingCommitLayerTree)
        return ts << "NotifyPendingCommitLayerTree";
    if (state == PendingCommitMessage::NotifyFlushingLayerTree)
        return ts << "NotifyFlushingLayerTree";
    return ts << "CommitLayerTree";
}

TextStream& operator<<(TextStream& ts, const CommitDelayState& state)
{
    switch (state) {
    case CommitDelayState::Pending: return ts << "Pending";
    case CommitDelayState::Delayed: return ts << "Delayed";
    case CommitDelayState::IntentionallyDeferred: return ts << "IntentionallyDeferred";
    }
}

TextStream& operator<<(TextStream& ts, const PendingCommit& pendingCommit)
{
    return ts << "{ " << pendingCommit.transactionID << ", pending(" << pendingCommit.pendingMessage << "), delay(" << pendingCommit.delayState << ") } ";
}

bool RemoteLayerTreeDrawingAreaProxy::allowMultipleCommitLayerTreePending()
{
    if (RefPtr page = this->page())
        return protect(page->preferences())->allowMultipleCommitLayerTreePending();
    return false;
}

bool ProcessState::canSendDisplayDidRefresh(RemoteLayerTreeDrawingAreaProxy& drawingArea)
{
    if (pendingCommits.size() >= 2)
        return false;
    if (pendingCommits.size() == 1)
        return drawingArea.allowMultipleCommitLayerTreePending() && pendingCommits[0].pendingMessage == PendingCommitMessage::CommitLayerTree && delayedCommits >= 4;
    return true;
}

IPC::Error RemoteLayerTreeDrawingAreaProxy::didRefreshDisplay(ProcessState& state, IPC::Connection& connection)
{
    if (!state.canSendDisplayDidRefresh(*this)) {
        ASSERT(state.pendingCommits.size());
        if (state.pendingCommits.last().delayState == CommitDelayState::Pending) {
            state.pendingCommits.last().delayState = CommitDelayState::Delayed;
            LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::didRefreshDisplay still waiting on commit, marked as delayed");
            state.delayedCommits++;
        }
        return IPC::Error::NoError;
    }

    state.pendingCommits.insert(0, { state.nextLayerTreeTransactionID, PendingCommitMessage::NotifyPendingCommitLayerTree, CommitDelayState::Pending });
    state.nextLayerTreeTransactionID.increment();

    LOG_WITH_STREAM(RemoteLayerTree, stream << "RemoteLayerTreeDrawingAreaProxy::didRefreshDisplay new state " << state.pendingCommits);

    if (&state == &m_webPageProxyProcessState) {
        if (RefPtr page = this->page())
            protect(page->scrollingCoordinatorProxy())->sendScrollingTreeNodeUpdate();
    }

    // Waiting for CA to commit is insufficient, because the render server can still be
    // using our backing store. We can improve this by waiting for the render server to commit
    // if we find API to do so, but for now we will make extra buffers if need be.
    return connection.send(Messages::DrawingArea::DisplayDidRefresh(MonotonicTime::now()), identifier());
}

void RemoteLayerTreeDrawingAreaProxy::didRefreshDisplay(IPC::Connection* connection)
{
    RefPtr page = this->page();
    if (!page || !page->hasRunningProcess())
        return;

    if (connection) {
        ProcessState& state = processStateForConnection(*connection);
        didRefreshDisplay(state, *connection);
    } else {
        forEachProcessState([&](ProcessState& state, WebProcessProxy& webProcess) {
            if (webProcess.hasConnection())
                didRefreshDisplay(state, protect(webProcess.connection()));
        });
    }

    if (maybePauseDisplayRefreshCallbacks())
        return;

    if (auto* page = this->page())
        page->didUpdateActivityState();
}

void RemoteLayerTreeDrawingAreaProxy::waitForDidUpdateActivityState(ActivityStateChangeID activityStateChangeID)
{
    ASSERT(activityStateChangeID != ActivityStateChangeAsynchronous);

    if (!webProcessProxy().hasConnection() || activityStateChangeID == ActivityStateChangeAsynchronous)
        return;

    Ref connection = webProcessProxy().connection();

    static Seconds activityStateUpdateTimeout = [] {
        if (RetainPtr<id> value = [[NSUserDefaults standardUserDefaults] objectForKey:@"WebKitOverrideActivityStateUpdateTimeout"])
            return Seconds([value doubleValue]);
        return 250_ms;
    }();

    WeakPtr weakThis { *this };
    auto startTime = MonotonicTime::now();

    do {
        IPC::Error error;
        if (!m_webPageProxyProcessState.pendingCommits.size())
            error = didRefreshDisplay(m_webPageProxyProcessState, connection.get());
        else {
            // Only the most recent outstanding frame can be in NotifyPendingCommitLayerTree state
            if (m_webPageProxyProcessState.pendingCommits[0].pendingMessage == PendingCommitMessage::NotifyPendingCommitLayerTree)
                error = connection->waitForAndDispatchImmediately<Messages::RemoteLayerTreeDrawingAreaProxy::NotifyPendingCommitLayerTree>(identifier(), activityStateUpdateTimeout - (MonotonicTime::now() - startTime), IPC::WaitForOption::InterruptWaitingIfSyncMessageArrives);
            else if (m_webPageProxyProcessState.pendingCommits[0].pendingMessage == PendingCommitMessage::NotifyFlushingLayerTree)
                error = connection->waitForAndDispatchImmediately<Messages::RemoteLayerTreeDrawingAreaProxy::NotifyFlushingLayerTree>(identifier(), activityStateUpdateTimeout - (MonotonicTime::now() - startTime), IPC::WaitForOption::InterruptWaitingIfSyncMessageArrives);
            else
                error = connection->waitForAndDispatchImmediately<Messages::RemoteLayerTreeDrawingAreaProxy::CommitLayerTree>(identifier(), activityStateUpdateTimeout - (MonotonicTime::now() - startTime), IPC::WaitForOption::InterruptWaitingIfSyncMessageArrives);
        }

        if (error != IPC::Error::NoError)
            return;
        if (!weakThis || activityStateChangeID <= m_activityStateChangeID)
            return;
    } while (true);
}

void RemoteLayerTreeDrawingAreaProxy::hideContentUntilPendingUpdate()
{
    if (!m_remoteLayerTreeHost)
        return;
    RELEASE_LOG(RemoteLayerTree, "RemoteLayerTreeDrawingAreaProxy(%" PRIu64 ")::hideContentUntilPendingUpdate", identifier().toUInt64());
    m_replyForUnhidingContent = webProcessProxy().sendWithAsyncReply(Messages::DrawingArea::DispatchAfterEnsuringDrawing(), [] () { }, messageSenderDestinationID(), { }, WebProcessProxy::ShouldStartProcessThrottlerActivity::No);
    m_remoteLayerTreeHost->detachRootLayer();
    m_hasDetachedRootLayer = true;

    // 10.9 backport: WebContent's rendering update sometimes doesn't fire
    // (CVDisplayLink unreliable on 10.9), so the DispatchAfterEnsuringDrawing
    // ack never returns → root stays detached → "white page until Safari restart"
    // (user 2026-05-17). Safety-net: after 750ms, if root is still detached,
    // force re-attach. The next live commit will overwrite it cleanly.
    WeakPtr<RemoteLayerTreeDrawingAreaProxy> weakThis { *this };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        RefPtr strong = weakThis.get();
        if (!strong || !strong->m_hasDetachedRootLayer || !strong->m_remoteLayerTreeHost)
            return;
        RELEASE_LOG(RemoteLayerTree, "RemoteLayerTreeDrawingAreaProxy(%" PRIu64 ") unhide-ack timeout — force re-attach", strong->identifier().toUInt64());
        if (RefPtr page = strong->page()) {
            auto rootNode = protect(strong->m_remoteLayerTreeHost->rootNode());
            page->setRemoteLayerTreeRootNode(rootNode.get());
            strong->m_hasDetachedRootLayer = false;
            strong->m_replyForUnhidingContent = std::nullopt;
        }
    });
}

void RemoteLayerTreeDrawingAreaProxy::hideContentUntilAnyUpdate()
{
    if (!m_remoteLayerTreeHost)
        return;
    RELEASE_LOG(RemoteLayerTree, "RemoteLayerTreeDrawingAreaProxy(%" PRIu64 ")::hideContentUntilAnyUpdate", identifier().toUInt64());
    m_remoteLayerTreeHost->detachRootLayer();
    m_hasDetachedRootLayer = true;
}

bool RemoteLayerTreeDrawingAreaProxy::hasVisibleContent() const
{
    return m_remoteLayerTreeHost->rootLayer();
}

CALayer *RemoteLayerTreeDrawingAreaProxy::layerWithIDForTesting(WebCore::PlatformLayerIdentifier layerID) const
{
    return m_remoteLayerTreeHost->layerWithIDForTesting(layerID);
}

void RemoteLayerTreeDrawingAreaProxy::minimumSizeForAutoLayoutDidChange()
{
    RefPtr page = this->page();
    if (!page || !page->hasRunningProcess())
        return;

    if (m_isWaitingForDidUpdateGeometry)
        return;

    sendUpdateGeometry();
}

void RemoteLayerTreeDrawingAreaProxy::sizeToContentAutoSizeMaximumSizeDidChange()
{
    RefPtr page = this->page();
    if (!page || !page->hasRunningProcess())
        return;

    if (m_isWaitingForDidUpdateGeometry)
        return;

    sendUpdateGeometry();
}

#if ENABLE(THREADED_ANIMATIONS)
void RemoteLayerTreeDrawingAreaProxy::animationsWereAddedToNode(RemoteLayerTreeNode& node)
{
    if (RefPtr page = this->page())
        protect(page->scrollingCoordinatorProxy())->animationsWereAddedToNode(node);
}

void RemoteLayerTreeDrawingAreaProxy::animationsWereRemovedFromNode(RemoteLayerTreeNode& node)
{
    if (RefPtr page = this->page())
        protect(page->scrollingCoordinatorProxy())->animationsWereRemovedFromNode(node);
}

void RemoteLayerTreeDrawingAreaProxy::updateTimelinesRegistration(WebCore::ProcessIdentifier processIdentifier, const WebCore::AcceleratedTimelinesUpdate& timelinesUpdate, MonotonicTime now)
{
    if (RefPtr page = this->page())
        protect(page->scrollingCoordinatorProxy())->updateTimelinesRegistration(processIdentifier, timelinesUpdate, now);
}

RefPtr<const RemoteAnimationTimeline> RemoteLayerTreeDrawingAreaProxy::timeline(const TimelineID& timelineID) const
{
    if (RefPtr page = this->page())
        return protect(page->scrollingCoordinatorProxy())->timeline(timelineID);
    return nullptr;
}

RefPtr<const RemoteAnimationStack> RemoteLayerTreeDrawingAreaProxy::animationStackForNodeWithIDForTesting(WebCore::PlatformLayerIdentifier layerID) const
{
    return m_remoteLayerTreeHost->animationStackForNodeWithIDForTesting(layerID);
}
#endif // ENABLE(THREADED_ANIMATIONS)

} // namespace WebKit
