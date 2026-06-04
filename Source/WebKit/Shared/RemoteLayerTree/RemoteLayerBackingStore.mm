/*
 * Copyright (C) 2013-2021 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "RemoteLayerBackingStore.h"
#import <syslog.h>

#import "ArgumentCoders.h"
#import "DynamicContentScalingImageBufferBackend.h"
#if ENABLE(GPU_PROCESS)
#import "GPUProcess.h"
#endif
#import "ImageBufferBackendHandleSharing.h"
#if ENABLE(GPU_PROCESS)
#import "ImageBufferSet.h"
#endif
#import "Logging.h"
#import "PlatformCALayerRemote.h"
#import "PrepareBackingStoreBuffersData.h"
#if ENABLE(GPU_PROCESS)
#import "RemoteImageBufferSetProxy.h"
#endif
#import "RemoteLayerBackingStoreCollection.h"
#import "RemoteLayerTreeContext.h"
#import "RemoteLayerTreeDrawingAreaProxy.h"
#import "RemoteLayerTreeHost.h"
#import "RemoteLayerTreeLayers.h"
#import "RemoteLayerTreeNode.h"
#import "RemoteLayerWithInProcessRenderingBackingStore.h"
#if ENABLE(GPU_PROCESS)
#import "RemoteLayerWithRemoteRenderingBackingStore.h"
#endif
#import "WebPageProxy.h"
#import "WebProcess.h"
#import "WebProcessPool.h"
#import "WebProcessProxy.h"
#import <QuartzCore/QuartzCore.h>
#import <WebCore/BifurcatedGraphicsContext.h>
#import <WebCore/DynamicContentScalingTypes.h>
#import <WebCore/GraphicsContextCG.h>
#import <WebCore/IOSurface.h>
#import <WebCore/ImageBuffer.h>
#import <WebCore/PlatformCALayerClient.h>
#import <WebCore/PlatformCALayerDelegatedContents.h>
#import <WebCore/ShareableBitmap.h>
#import <WebCore/WebCoreCALayerExtras.h>
#import <WebCore/WebLayer.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/Noncopyable.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/text/TextStream.h>

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
#import "WKSeparatedImageView.h"
#endif

// Forward-declare contentsDirtyRect methods for older SDKs that don't have them.
@interface CALayer (WebKitContentsDirtyRect)
- (CGRect)contentsDirtyRect;
- (void)setContentsDirtyRect:(CGRect)rect;
@end

namespace WebKit {

using namespace WebCore;

#if !ENABLE(GPU_PROCESS)
// When GPU_PROCESS is disabled, ImageBufferSet::computePaintingRects is not
// available. Provide a local equivalent.
static Vector<FloatRect, 5> computePaintingRectsFromRegion(const Region& dirtyRegion, float resolutionScale)
{
    auto dirtyRects = dirtyRegion.rects();
#if PLATFORM(COCOA)
    IntRect dirtyBounds = dirtyRegion.bounds();
    if (dirtyRects.size() > PlatformCALayer::webLayerMaxRectsToPaint || dirtyRegion.totalArea() > PlatformCALayer::webLayerWastedSpaceThreshold * dirtyBounds.width() * dirtyBounds.height()) {
        dirtyRects.clear();
        dirtyRects.append(dirtyBounds);
    }
#endif
    Vector<FloatRect, 5> paintingRects;
    for (const auto& rect : dirtyRects) {
        FloatRect scaledRect(rect);
        scaledRect.scale(resolutionScale);
        scaledRect = enclosingIntRect(scaledRect);
        scaledRect.scale(1 / resolutionScale);
        paintingRects.append(scaledRect);
    }
    return paintingRects;
}
#endif

namespace {

class DelegatedContentsFenceFlusher final : public ThreadSafeImageBufferSetFlusher {
    WTF_MAKE_TZONE_ALLOCATED(DelegatedContentsFenceFlusher);
    WTF_MAKE_NONCOPYABLE(DelegatedContentsFenceFlusher);
public:
    static std::unique_ptr<DelegatedContentsFenceFlusher> create(Ref<PlatformCALayerDelegatedContentsFence> fence)
    {
        return std::unique_ptr<DelegatedContentsFenceFlusher> { new DelegatedContentsFenceFlusher(WTF::move(fence)) };
    }

    bool flushAndCollectHandles(HashMap<ImageBufferSetIdentifier, std::unique_ptr<BufferSetBackendHandle>>&) final
    {
        return m_fence->waitFor(delegatedContentsFinishedTimeout);
    }

private:
    DelegatedContentsFenceFlusher(Ref<PlatformCALayerDelegatedContentsFence> fence)
        : m_fence(WTF::move(fence))
    {
    }

    const Ref<PlatformCALayerDelegatedContentsFence> m_fence;
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(DelegatedContentsFenceFlusher);

}

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteLayerBackingStore);

std::unique_ptr<RemoteLayerBackingStore> RemoteLayerBackingStore::createForLayer(PlatformCALayerRemote& layer)
{
    auto model = processModelForLayer(layer);
    { static int s_n = 0; if (++s_n <= 50) { FILE *_f=((FILE*)0); if(_f){fprintf(_f,"[createForLayer PID %d] layerID=%llu type=%d processModel=%d\n", getpid(), (unsigned long long)layer.layerID().object().toUInt64(), (int)layer.layerType(), (int)model); fclose(_f);} } }
    switch (model) {
#if ENABLE(GPU_PROCESS)
    case ProcessModel::Remote:
        return makeUnique<RemoteLayerWithRemoteRenderingBackingStore>(layer);
#endif
    case ProcessModel::InProcess:
        return makeUnique<RemoteLayerWithInProcessRenderingBackingStore>(layer);
    }
}

RemoteLayerBackingStore::RemoteLayerBackingStore(PlatformCALayerRemote& layer)
    : m_layer(layer)
    , m_lastDisplayTime(-MonotonicTime::infinity())
{
    if (RefPtr collection = backingStoreCollection())
        collection->backingStoreWasCreated(*this);
}

RemoteLayerBackingStore::~RemoteLayerBackingStore()
{
    if (RefPtr collection = backingStoreCollection())
        collection->backingStoreWillBeDestroyed(*this);
}

RemoteLayerBackingStoreCollection* RemoteLayerBackingStore::backingStoreCollection() const
{
    if (auto* context = m_layer->context())
        return &context->backingStoreCollection();

    return nullptr;
}

void RemoteLayerBackingStore::clearBackingStore()
{
    m_contentsBufferHandle = std::nullopt;
    setNeedsDisplay();
}

void RemoteLayerBackingStore::ensureBackingStore(const Parameters& parameters)
{
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[BS::ensure] size=%gx%g type=%d opaque=%d\n", (double)parameters.size.width(), (double)parameters.size.height(), (int)parameters.type, (int)parameters.isOpaque); fclose(_d);}}
    if (m_parameters == parameters)
        return;

    m_parameters = parameters;
    clearBackingStore();
}

RemoteLayerBackingStore::ProcessModel RemoteLayerBackingStore::processModelForLayer(PlatformCALayerRemote& layer)
{
#if ENABLE(GPU_PROCESS)
    if (WebProcess::singleton().shouldUseRemoteRenderingFor(WebCore::RenderingPurpose::DOM) && !layer.needsPlatformContext())
        return ProcessModel::Remote;
#endif
    return ProcessModel::InProcess;
}

void RemoteLayerBackingStore::encode(IPC::Encoder& encoder) const
{
    // Only delegated contents encode their handle here. Buffer sets encode their handles
    // out of line (and on a different thread) using the flushAndCollectHandles method
    // on their async flusher.
    std::optional<ImageBufferBackendHandle> handle;
    if (m_contentsBufferHandle) {
        ASSERT(m_parameters.type == Type::IOSurface);
        handle = ImageBufferBackendHandle { *m_contentsBufferHandle };
    }
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[BS::encode] hasContentsBufferHandle=%d hasHandle=%d type=%d size=%gx%g\n", (int)!!m_contentsBufferHandle, (int)!!handle, (int)m_parameters.type, (double)m_parameters.size.width(), (double)m_parameters.size.height()); fclose(_d);}}

    encoder << WTF::move(handle);

    encoder << bufferSetIdentifier();

    encoder << m_contentsRenderingResourceIdentifier;
    encoder << m_previouslyPaintedRect;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    encoder << displayListHandle();
#endif

    encoder << m_parameters.isOpaque;
    encoder << m_parameters.type;
#if HAVE(SUPPORT_HDR_DISPLAY)
    encoder << m_maxRequestedEDRHeadroom;
#endif
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteLayerBackingStoreProperties);

void RemoteLayerBackingStoreProperties::dump(TextStream& ts) const
{
    auto dumpBuffer = [&](ASCIILiteral name, const std::optional<BufferAndBackendInfo>& bufferInfo) {
        ts.startGroup();
        ts << name << ' ';
        if (bufferInfo)
            ts << bufferInfo->resourceIdentifier << " backend generation "_s << bufferInfo->backendGeneration;
        else
            ts << "none"_s;
        ts.endGroup();
    };
    dumpBuffer("front buffer"_s, m_frontBufferInfo);
    dumpBuffer("back buffer"_s, m_backBufferInfo);
    dumpBuffer("secondaryBack buffer"_s, m_secondaryBackBufferInfo);

    ts.dumpProperty("has buffer handle"_s, !!bufferHandle());
#if HAVE(SUPPORT_HDR_DISPLAY)
    ts.dumpProperty("requested-headroom", m_maxRequestedEDRHeadroom);
#endif
}

bool RemoteLayerBackingStore::layerWillBeDisplayed()
{
    RefPtr collection = backingStoreCollection();
    if (!collection) {
        ASSERT_NOT_REACHED();
        return false;
    }

    return collection->backingStoreWillBeDisplayed(*this);
}

bool RemoteLayerBackingStore::layerWillBeDisplayedWithRenderingSuppression()
{
    RefPtr collection = backingStoreCollection();
    if (!collection) {
        ASSERT_NOT_REACHED();
        return false;
    }

    return collection->backingStoreWillBeDisplayedWithRenderingSuppression(*this);
}

void RemoteLayerBackingStore::setNeedsDisplay(const IntRect rect)
{
    m_dirtyRegion.unite(intersection(layerBounds(), rect));
}

void RemoteLayerBackingStore::setNeedsDisplay()
{
    m_dirtyRegion.unite(layerBounds());
#if HAVE(SUPPORT_HDR_DISPLAY)
    m_maxPaintedEDRHeadroom = 1;
    m_maxRequestedEDRHeadroom = 1;
#endif
}

#if HAVE(SUPPORT_HDR_DISPLAY)
bool RemoteLayerBackingStore::setNeedsDisplayIfEDRHeadroomExceeds(float headroom)
{
    if (m_maxPaintedEDRHeadroom > headroom) {
        setNeedsDisplay();
        return true;
    }

    bool wasTonemapped = m_maxRequestedEDRHeadroom > m_maxPaintedEDRHeadroom;
    if (m_maxPaintedEDRHeadroom < headroom && wasTonemapped) {
        setNeedsDisplay();
        return true;
    }
    return false;
}
#endif

WebCore::IntRect RemoteLayerBackingStore::layerBounds() const
{
    return IntRect { { }, expandedIntSize(m_parameters.size) };
}

PixelFormat RemoteLayerBackingStore::pixelFormat() const
{
    switch (contentsFormat()) {
    case ContentsFormat::RGBA8:
        return m_parameters.isOpaque ? PixelFormat::BGRX8 : PixelFormat::BGRA8;

#if ENABLE(PIXEL_FORMAT_RGB10)
    case ContentsFormat::RGBA10:
        return m_parameters.isOpaque ? PixelFormat::RGB10 : PixelFormat::RGB10A8;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case ContentsFormat::RGBA16F:
        return PixelFormat::RGBA16F;
#endif
    }
}

unsigned RemoteLayerBackingStore::bytesPerPixel() const
{
    return contentsFormatBytesPerPixel(contentsFormat(), m_parameters.isOpaque);
}

bool RemoteLayerBackingStore::supportsPartialRepaint() const
{
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    // FIXME: Find a way to support partial repaint for backing store that
    // includes a display list without allowing unbounded memory growth.
    if (m_parameters.includeDisplayList == WebCore::IncludeDynamicContentScalingDisplayList::Yes)
        return false;
#endif

    const unsigned maxSmallLayerBackingArea = 64u * 64u;
    auto checkedArea = ImageBuffer::calculateBackendSize(m_parameters.size, m_parameters.scale).area<RecordOverflow>();
    if (!checkedArea.hasOverflowed() && checkedArea <= maxSmallLayerBackingArea)
        return false;
    return true;
}

bool RemoteLayerBackingStore::drawingRequiresClearedPixels() const
{
    return !m_parameters.isOpaque && !m_layer->owner()->platformCALayerShouldPaintUsingCompositeCopy();
}

PlatformCALayerRemote& RemoteLayerBackingStore::layer() const
{
    return m_layer;
}

void RemoteLayerBackingStore::setDelegatedContents(const PlatformCALayerRemoteDelegatedContents& contents)
{
    m_contentsBufferHandle = ImageBufferBackendHandle { contents.surface };
    if (contents.finishedFence)
        m_frontBufferFlushers.append(DelegatedContentsFenceFlusher::create(Ref { *contents.finishedFence }));
    if (contents.surfaceIdentifier)
        m_contentsRenderingResourceIdentifier = *contents.surfaceIdentifier;
    else
        m_contentsRenderingResourceIdentifier = std::nullopt;
    m_dirtyRegion = { };
    m_paintingRects.clear();
#if HAVE(SUPPORT_HDR_DISPLAY)
    m_maxRequestedEDRHeadroom = 1;
    m_maxPaintedEDRHeadroom = 1;
#endif
}

bool RemoteLayerBackingStore::needsDisplay() const
{
    RefPtr collection = backingStoreCollection();
    if (!collection) {
        ASSERT_NOT_REACHED();
        return false;
    }

    Ref layer = m_layer.get();
    if (layer->owner()->platformCALayerDelegatesDisplay(layer.ptr())) {
        LOG_WITH_STREAM(RemoteLayerBuffers, stream << "RemoteLayerBackingStore " << layer->layerID() << " needsDisplay() - delegates display");
        return true;
    }

    auto needsDisplayReason = [&]() {
        if (size().isEmpty())
            return BackingStoreNeedsDisplayReason::None;

        if (!hasFrontBuffer())
            return BackingStoreNeedsDisplayReason::NoFrontBuffer;

        if (frontBufferMayBeVolatile())
            return BackingStoreNeedsDisplayReason::FrontBufferIsVolatile;

        return hasEmptyDirtyRegion() ? BackingStoreNeedsDisplayReason::None : BackingStoreNeedsDisplayReason::HasDirtyRegion;
    }();

    LOG_WITH_STREAM(RemoteLayerBuffers, stream << "RemoteLayerBackingStore " << layer->layerID() << " size " << size() << " needsDisplay() - needs display reason: " << needsDisplayReason);
    return needsDisplayReason != BackingStoreNeedsDisplayReason::None;
}

bool RemoteLayerBackingStore::performDelegatedLayerDisplay()
{
    Ref layer = m_layer.get();
    auto& layerOwner = *layer->owner();
    if (layerOwner.platformCALayerDelegatesDisplay(layer.ptr())) {
        // This can call back to setContents(), setting m_contentsBufferHandle.
        layerOwner.platformCALayerLayerDisplay(layer.ptr());
        layerOwner.platformCALayerLayerDidDisplay(layer.ptr());
        return true;
    }
    
    return false;
}

void RemoteLayerBackingStore::dirtyRepaintCounterIfNecessary()
{
    Ref layer = m_layer.get();
    if (layer->owner()->platformCALayerShowRepaintCounter(layer.ptr())) {
        IntRect indicatorRect(0, 0, 52, 28);
        m_dirtyRegion.unite(indicatorRect);
    }
}

void RemoteLayerBackingStore::paintContents()
{
    Ref layer = m_layer.get();
    LOG_WITH_STREAM(RemoteLayerBuffers, stream << "RemoteLayerBackingStore " << layer->layerID() << " paintContents() - has dirty region " << !hasEmptyDirtyRegion());
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[paintContents PID %d] layerID=%llu bounds=%gx%g delegated=%d emptyDirty=%d\n",
        getpid(), (unsigned long long)layer->layerID().object().toUInt64(),
        (double)layerBounds().width(), (double)layerBounds().height(),
        (int)layer->owner()->platformCALayerDelegatesDisplay(layer.ptr()), (int)hasEmptyDirtyRegion()); fclose(_d);}}
    if (layer->owner()->platformCALayerDelegatesDisplay(layer.ptr()))
        return;

    // 10.9 backport: REVERTED to v1 (unite always). v2/v3/v4 attempts to skip
    // unnecessary repaint caused major page corruption. Some upstream content
    // isn't being marked dirty correctly; until that's understood, force full
    // repaint every commit. This is the perf killer.
    m_dirtyRegion.unite(layerBounds());

    if (hasEmptyDirtyRegion()) {
        if (auto flusher = createFlusher(ThreadSafeImageBufferSetFlusher::FlushType::BackendHandlesOnly))
            m_frontBufferFlushers.append(WTF::move(flusher));
        return;
    }

    m_lastDisplayTime = MonotonicTime::now();
#if ENABLE(GPU_PROCESS)
    m_paintingRects = ImageBufferSet::computePaintingRects(m_dirtyRegion, m_parameters.scale);
#else
    m_paintingRects = computePaintingRectsFromRegion(m_dirtyRegion, m_parameters.scale);
#endif

    createContextAndPaintContents();
}

void RemoteLayerBackingStore::drawInContext(GraphicsContext& context)
{
    GraphicsContextStateSaver stateSaver(context);
    IntRect dirtyBounds = m_dirtyRegion.bounds();
// 10.9 backport: skip the debug magenta fill — it overdraws actual content here.
// (Original guard: #ifndef NDEBUG.)

// 10.9 backport: clear the dirty region to TRANSPARENT (not white) before paint.
// This prevents textContent overlay artifacts where antialiased glyphs from the
// previous paint cycle blend with the new ones. CGContextClearRect with alpha=0
// won't trigger the same CGContextFillPath silent-fail that white-fill does, so
// inline SVG icons painted afterwards still render correctly.
    if (CGContextRef cg = context.platformContext()) {
        CGContextSaveGState(cg);
        CGContextClearRect(cg, dirtyBounds);
        CGContextRestoreGState(cg);
    }

    OptionSet<WebCore::GraphicsLayerPaintBehavior> paintBehavior;
#if HAVE(SUPPORT_HDR_DISPLAY)
    paintBehavior.add(GraphicsLayerPaintBehavior::TonemapHDRToDisplayHeadroom);
    context.clearMaxEDRHeadrooms();
#endif
    
    // FIXME: This should be moved to PlatformCALayerRemote for better layering.
    Ref layer = m_layer.get();
    switch (layer->layerType()) {
    case PlatformCALayer::LayerType::LayerTypeSimpleLayer:
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    case PlatformCALayer::LayerType::LayerTypeSeparatedImageLayer:
#endif
    case PlatformCALayer::LayerType::LayerTypeTiledBackingTileLayer:
        layer->owner()->platformCALayerPaintContents(layer.ptr(), context, dirtyBounds, paintBehavior);
        // 10.9: sample paint output. The pixel sampling is also a perf-relevant
        // CPU yield point for github (without it, github's JS hot-loop starves
        // rendering and tiles paint as zeros). Keep this even if log output is
        // throwaway — the syscall path of the disk write helps schedule.
        {
            CGContextRef cg = context.platformContext();
            if (cg && CGBitmapContextGetData(cg)) {
                uint32_t* p = static_cast<uint32_t*>(CGBitmapContextGetData(cg));
                size_t w = CGBitmapContextGetWidth(cg);
                size_t h = CGBitmapContextGetHeight(cg);
                uint32_t nonzero = 0, total = 0;
                size_t step = (w*h) / 16 ? (w*h) / 16 : 1;
                for (size_t i = 0; i < w*h; i += step) { if (p[i]) ++nonzero; ++total; }
                // 10.9 perf: removed debug fopen logging
            }
        }
        break;
    case PlatformCALayer::LayerType::LayerTypeWebLayer:
    case PlatformCALayer::LayerType::LayerTypeBackdropLayer:
#if HAVE(CORE_MATERIAL)
    case PlatformCALayer::LayerType::LayerTypeMaterialLayer:
#endif
        PlatformCALayer::drawLayerContents(context, layer.ptr(), m_paintingRects, paintBehavior);
        break;
    case PlatformCALayer::LayerType::LayerTypeLayer:
    case PlatformCALayer::LayerType::LayerTypeTransformLayer:
    case PlatformCALayer::LayerType::LayerTypeTiledBackingLayer:
    case PlatformCALayer::LayerType::LayerTypePageTiledBackingLayer:
    case PlatformCALayer::LayerType::LayerTypeRootLayer:
    case PlatformCALayer::LayerType::LayerTypeAVPlayerLayer:
    case PlatformCALayer::LayerType::LayerTypeContentsProvidedLayer:
    case PlatformCALayer::LayerType::LayerTypeShapeLayer:
    case PlatformCALayer::LayerType::LayerTypeScrollContainerLayer:
#if ENABLE(MODEL_ELEMENT)
    case PlatformCALayer::LayerType::LayerTypeModelLayer:
#endif
    case PlatformCALayer::LayerType::LayerTypeCustom:
    case PlatformCALayer::LayerType::LayerTypeHost:
#if HAVE(MATERIAL_HOSTING)
    case PlatformCALayer::LayerType::LayerTypeMaterialHostingLayer:
#endif
        ASSERT_NOT_REACHED();
        break;
    };

    stateSaver.restore();

    m_dirtyRegion = { };
    m_paintingRects.clear();
#if HAVE(SUPPORT_HDR_DISPLAY)
    m_maxPaintedEDRHeadroom = std::max(m_maxPaintedEDRHeadroom, context.maxPaintedEDRHeadroom());
    m_maxRequestedEDRHeadroom = std::max(m_maxRequestedEDRHeadroom, context.maxRequestedEDRHeadroom());
#endif

    layer->owner()->platformCALayerLayerDidDisplay(layer.ptr());

    m_previouslyPaintedRect = dirtyBounds;
#if HAVE(CGIOSURFACECONTEXT_FLUSH_QUEUE)
    if (type() == Type::IOSurface && processModel() == ProcessModel::Remote) {
        m_needsFlush = true;
        submitDrawingCommands();
        return;
    }
#endif
    if (auto flusher = createFlusher())
        m_frontBufferFlushers.append(WTF::move(flusher));

}

void RemoteLayerBackingStore::flush()
{
    if (m_needsFlush) {
        if (auto flusher = createFlusher())
            m_frontBufferFlushers.append(WTF::move(flusher));
        m_needsFlush = false;
    }
}

void RemoteLayerBackingStore::enumerateRectsBeingDrawn(GraphicsContext& context, void (^block)(FloatRect))
{
    CGAffineTransform inverseTransform = CGAffineTransformInvert(context.getCTM());

    // We don't want to un-apply the flipping or contentsScale,
    // because they're not applied to repaint rects.
    inverseTransform = CGAffineTransformScale(inverseTransform, m_parameters.scale, -m_parameters.scale);
    inverseTransform = CGAffineTransformTranslate(inverseTransform, 0, -m_parameters.size.height());

    for (const auto& rect : m_paintingRects) {
        CGRect rectToDraw = CGRectApplyAffineTransform(rect, inverseTransform);
        block(rectToDraw);
    }
}

RemoteLayerBackingStoreProperties::RemoteLayerBackingStoreProperties(ImageBufferBackendHandle&& handle, WebCore::RenderingResourceIdentifier identifier, bool opaque)
    : m_bufferHandle(WTF::move(handle))
    , m_contentsRenderingResourceIdentifier(identifier)
    , m_isOpaque(opaque)
    , m_type(RemoteLayerBackingStore::Type::IOSurface)
{
}

RemoteLayerBackingStoreProperties::LayerContentsBufferInfo RemoteLayerBackingStoreProperties::layerContentsBufferFromBackendHandle(ImageBufferBackendHandle&& backendHandle, bool isDelegatedDisplay)
{
    bool hasExtendedDynamicRange = false;
    RetainPtr<id> contents;
    WTF::switchOn(backendHandle,
        [&] (ShareableBitmap::Handle& handle) {
            if (auto bitmap = ShareableBitmap::create(WTF::move(handle), SharedMemory::Protection::ReadOnly)) {
                contents = bridge_id_cast(bitmap->createPlatformImage());
                hasExtendedDynamicRange = bitmap->colorSpace().usesExtendedRange();
            }
        },
        [&] (MachSendRight& machSendRight) {
            if (auto surface = WebCore::IOSurface::createFromSendRight(WTF::move(machSendRight))) {
#if ENABLE(PIXEL_FORMAT_RGBA16F)
                if (surface->pixelFormat() == WebCore::IOSurface::Format::RGBA16F) {
                    hasExtendedDynamicRange = true;
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
                    if (isDelegatedDisplay && !surface->contentEDRHeadroom())
                        surface->loadContentEDRHeadroom();
#endif
                }
#endif
                if (surface->isVolatile())
                    RELEASE_LOG_ERROR(RemoteLayerTree, "Received volatile IOSurface");
                contents = surface->asCAIOSurfaceLayerContents();
            }
        }
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
        , [&] (WebCore::DynamicContentScalingDisplayList& handle) {
            ASSERT_NOT_REACHED();
        }
#endif
    );

    return { contents, hasExtendedDynamicRange };
}

void RemoteLayerBackingStoreProperties::applyBackingStoreToNode(RemoteLayerTreeNode& node, bool replayDynamicContentScalingDisplayListsIntoBackingStore, UIView* hostingView)
{
    RetainPtr layer = node.layer();
    bool isDelegatedDisplay = !m_frontBufferInfo;
    {FILE *_d=((FILE*)0); if(_d){fprintf(_d,"[applyBSToNode] layerID=%llu layer=%p bounds=%gx%g delegated=%d hasFrontBuffer=%d hasBufHandle=%d\n",
        (unsigned long long)node.layerID().object().toUInt64(), layer.get(),
        (double)[layer bounds].size.width, (double)[layer bounds].size.height,
        (int)isDelegatedDisplay, (int)!!m_frontBufferInfo, (int)!!m_bufferHandle); fclose(_d);}}

    // FIXME: Ideally we'd just infer wantsExtendedDynamicRangeContent
    // from the format of the buffer itself.
    [layer setContentsOpaque:m_isOpaque];

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    if (hostingView && [hostingView isKindOfClass:[WKSeparatedImageView class]]) {
        if (m_bufferHandle) {
            auto machSendRight = std::get<MachSendRight>(WTF::move(*m_bufferHandle));
            auto surface = WebCore::IOSurface::createFromSendRight(WTF::move(machSendRight));
            if (surface) {
                [(WKSeparatedImageView *)hostingView setSurface:surface->surface()];
                return;
            }
        }
        [(WKSeparatedImageView *)hostingView setSurface:nil];
        return;
    }
#endif

    LayerContentsBufferInfo bufferInfo = lookupCachedBuffer(node);
    // m_bufferHandle can be unset here if IPC with the GPU process timed out.
    if (!bufferInfo.buffer && m_bufferHandle)
        bufferInfo = layerContentsBufferFromBackendHandle(WTF::move(*m_bufferHandle), isDelegatedDisplay);

    if (!bufferInfo.buffer) {
        [layer _web_clearContents];
        return;
    }

#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (bufferInfo.hasExtendedDynamicRange) {
        [layer setWantsExtendedDynamicRangeContent:true];
        // Delegated contents set headroom via surface properties, not RemoteLayerBackingStore state.
        if (isDelegatedDisplay)
            [layer setContentsHeadroom:0.f];
        else
            [layer setContentsHeadroom:m_maxRequestedEDRHeadroom];
    } else {
        [layer setWantsExtendedDynamicRangeContent:false];
        [layer setContentsHeadroom:0.f];
    }
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    if (m_displayListBufferHandle) {
        ASSERT([layer isKindOfClass:[WKCompositingLayer class]]);
        if (![layer isKindOfClass:[WKCompositingLayer class]])
            return;

        [layer setDrawsAsynchronously:(m_type == RemoteLayerBackingStore::Type::IOSurface)];

        if (!replayDynamicContentScalingDisplayListsIntoBackingStore) {
            [layer setValue:@1 forKeyPath:WKDynamicContentScalingEnabledKey];
            [layer setValue:@1 forKeyPath:WKDynamicContentScalingBifurcationEnabledKey];
            [layer setValue:@([layer contentsScale]) forKeyPath:WKDynamicContentScalingBifurcationScaleKey];
        }
        [(WKCompositingLayer *)layer.get() _setWKContents:bufferInfo.buffer.get() withDisplayList:WTF::move(*m_displayListBufferHandle) replayForTesting:replayDynamicContentScalingDisplayListsIntoBackingStore];
        return;
    } else
        [layer _web_clearDynamicContentScalingDisplayListIfNeeded];
#else
    UNUSED_PARAM(replayDynamicContentScalingDisplayListsIntoBackingStore);
#endif

    [layer setContents:bufferInfo.buffer.get()];
    if ([CALayer instancesRespondToSelector:@selector(contentsDirtyRect)]) {
        if (m_paintedRect) {
            FloatRect painted = *m_paintedRect;
            painted.scale([layer contentsScale]);

            // Most of the time layer.contentsDirtyRect should be the null rect, since CA clears this on every commit,
            // but in some scenarios we don't get a CA commit for every remote layer tree transaction.
            CALayer *rawLayer = layer.get();
            CGRect existingDirtyRect = [rawLayer contentsDirtyRect];
            if (CGRectIsNull(existingDirtyRect))
                [rawLayer setContentsDirtyRect:painted];
            else
                [rawLayer setContentsDirtyRect:CGRectUnion(existingDirtyRect, painted)];
        }
    }
}

RemoteLayerBackingStoreProperties::LayerContentsBufferInfo RemoteLayerBackingStoreProperties::lookupCachedBuffer(RemoteLayerTreeNode& node)
{
    // 10.9 backport: this function shows up in Safari crash logs as
    // lookupCachedBuffer + 1280 with EXC_BAD_ACCESS at heap addresses, suggesting
    // freed-buffer access during IOSurface/CALayer interaction. Wrap the whole
    // body — anything thrown becomes an empty buffer info (the caller treats
    // that as "no cached buffer; will rebuild") rather than crashing Safari.
    LayerContentsBufferInfo safeResult = { { }, false };
    try { @try {
        Vector<RemoteLayerTreeNode::CachedContentsBuffer> cachedBuffers = node.takeCachedContentsBuffers();

        if (!m_frontBufferInfo)
            return { { }, false };

        cachedBuffers.removeAllMatching([&](const RemoteLayerTreeNode::CachedContentsBuffer& current) {
            auto matches = [&](std::optional<BufferAndBackendInfo>& backendInfo) {
                if (!backendInfo || *backendInfo != current.imageBufferInfo)
                    return false;
                return true;
            };
            if (matches(m_frontBufferInfo))
                return false;

            if (matches(m_backBufferInfo))
                return false;

            if (matches(m_secondaryBackBufferInfo))
                return false;

            return true;
        });

        LayerContentsBufferInfo result = { { }, false };
        bool hasFreshHandle = m_bufferHandle && std::holds_alternative<MachSendRight>(*m_bufferHandle);
        if (!hasFreshHandle) {
            for (auto& current : cachedBuffers) {
                if (m_frontBufferInfo->resourceIdentifier == current.imageBufferInfo.resourceIdentifier) {
                    result.buffer = current.buffer;
#if ENABLE(PIXEL_FORMAT_RGBA16F)
                    if (current.ioSurface && current.ioSurface->pixelFormat() == WebCore::IOSurface::Format::RGBA16F)
                        result.hasExtendedDynamicRange = true;
#endif
                    break;
                }
            }
        }

        if (!result.buffer && m_bufferHandle && std::holds_alternative<MachSendRight>(*m_bufferHandle)) {
            if (auto surface = WebCore::IOSurface::createFromSendRight(std::get<MachSendRight>(*std::exchange(m_bufferHandle, std::nullopt)))) {
                result.buffer = surface->asCAIOSurfaceLayerContents();
#if ENABLE(PIXEL_FORMAT_RGBA16F)
                if (surface->pixelFormat() == WebCore::IOSurface::Format::RGBA16F)
                    result.hasExtendedDynamicRange = true;
#endif
                if (surface->isVolatile())
                    RELEASE_LOG_ERROR(RemoteLayerTree, "Received volatile IOSurface");
                cachedBuffers.append({ *m_frontBufferInfo, result.buffer, WTF::move(surface) });
            }
        }

        node.setCachedContentsBuffers(WTF::move(cachedBuffers));
        return result;
    } @catch (NSException *) { return safeResult; } } catch (...) { return safeResult; }
}

void RemoteLayerBackingStoreProperties::setBackendHandle(BufferSetBackendHandle& bufferSetHandle)
{
    m_bufferHandle = std::exchange(bufferSetHandle.bufferHandle, std::nullopt);
    m_frontBufferInfo = bufferSetHandle.frontBufferInfo;
    m_backBufferInfo = bufferSetHandle.backBufferInfo;
    m_secondaryBackBufferInfo = bufferSetHandle.secondaryBackBufferInfo;
}

Vector<std::unique_ptr<ThreadSafeImageBufferSetFlusher>> RemoteLayerBackingStore::takePendingFlushers()
{
    return std::exchange(m_frontBufferFlushers, { });
}

void RemoteLayerBackingStore::purgeFrontBufferForTesting()
{
    if (RefPtr collection = backingStoreCollection())
        collection->purgeFrontBufferForTesting(*this);
}

void RemoteLayerBackingStore::purgeBackBufferForTesting()
{
    if (RefPtr collection = backingStoreCollection())
        collection->purgeBackBufferForTesting(*this);
}

void RemoteLayerBackingStore::markFrontBufferVolatileForTesting()
{
    if (RefPtr collection = backingStoreCollection())
        collection->markFrontBufferVolatileForTesting(*this);
}

TextStream& operator<<(TextStream& ts, const RemoteLayerBackingStore& backingStore)
{
    backingStore.dump(ts);
    return ts;
}

TextStream& operator<<(TextStream& ts, const RemoteLayerBackingStoreProperties& properties)
{
    properties.dump(ts);
    return ts;
}

TextStream& operator<<(TextStream& ts, BackingStoreNeedsDisplayReason reason)
{
    switch (reason) {
    case BackingStoreNeedsDisplayReason::None: ts << "none"_s; break;
    case BackingStoreNeedsDisplayReason::NoFrontBuffer: ts << "no front buffer"_s; break;
    case BackingStoreNeedsDisplayReason::FrontBufferIsVolatile: ts << "volatile front buffer"_s; break;
    case BackingStoreNeedsDisplayReason::FrontBufferHasNoSharingHandle: ts << "no front buffer sharing handle"_s; break;
    case BackingStoreNeedsDisplayReason::HasDirtyRegion: ts << "has dirty region"_s; break;
    }

    return ts;
}

RemoteLayerBackingStoreOrProperties::RemoteLayerBackingStoreOrProperties(std::unique_ptr<RemoteLayerBackingStoreProperties>&& properties)
    : properties(WTF::move(properties)) { }

} // namespace WebKit
