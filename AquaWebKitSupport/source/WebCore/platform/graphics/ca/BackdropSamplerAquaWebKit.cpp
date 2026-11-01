#include "config.h"
#include "BackdropSamplerAquaWebKit.h"

#include "CSSFilterRenderer.h"
#include "Color.h"
#include "FEGaussianBlur.h"
#include "FilterOperations.h"
#include "FilterResults.h"
#include "FloatQuad.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "ImageBuffer.h"
#include "PixelBuffer.h"
#include "TransformationMatrix.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(BackdropSampler);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(BackdropSampler::Inputs);

// The content beneath a backdrop is painted at two pixels per standard deviation of the smallest blur its chain
// shows, which holds all that blur leaves of it, and at most this many pixels along the image's longer side.
static constexpr float pixelsPerDeviation = 2;
static constexpr float maximumSampleLength = 256;
// The content beneath a blur of under a pixel, which barely changes it, shows through the backdrop's fill.
static constexpr float minimumSampledDeviation = 1;
// The backdrop layer fades each image in over this time.
static constexpr Seconds minimumPaintInterval = 100_ms;

using ScrollGeometries = BackdropSampler::ScrollGeometries;

static FloatPoint layerPosition(const GraphicsLayer& layer, const ScrollGeometries& geometries)
{
    auto geometry = geometries.find(&layer);
    return geometry != geometries.end() && geometry->value.position ? *geometry->value.position : layer.position();
}

static FloatPoint layerBoundsOrigin(const GraphicsLayer& layer, const ScrollGeometries& geometries)
{
    auto geometry = geometries.find(&layer);
    return geometry != geometries.end() && geometry->value.boundsOrigin ? *geometry->value.boundsOrigin : layer.boundsOrigin();
}

static FloatSize layerSize(const GraphicsLayer& layer, const ScrollGeometries& geometries)
{
    auto geometry = geometries.find(&layer);
    return geometry != geometries.end() && geometry->value.size ? *geometry->value.size : layer.size();
}

// A layer whose transform animates sits where the animation has it now, as GraphicsLayerCA places it for its
// coverage rect.
static TransformationMatrix anchoredTransform(const GraphicsLayer& layer)
{
    auto matrix = layer.transform();
    if (layer.animatesTransform())
        layer.client().getCurrentTransform(&layer, matrix);
    if (matrix.isIdentity())
        return matrix;
    FloatPoint3D anchor = layer.anchorPoint();
    anchor.scale(layer.size().width(), layer.size().height(), 1);
    TransformationMatrix result;
    result.translate3d(anchor.x(), anchor.y(), anchor.z());
    result.multiply(matrix);
    result.translate3d(-anchor.x(), -anchor.y(), -anchor.z());
    return result;
}

// The sublayers Core Animation shows; past its maximum tree depth, GraphicsLayerCA commits none.
static const Vector<Ref<GraphicsLayer>>& shownChildren(const GraphicsLayer& layer)
{
    static NeverDestroyed<Vector<Ref<GraphicsLayer>>> none;
    return layer.commitsSublayers() ? layer.children() : none.get();
}

// Maps a point in `layer`'s bounds coordinates into its parent's, as GraphicsLayerCA lays layers out. Without
// its transform, it maps the layer's animation extent, which the transform already applies to.
static TransformationMatrix layerToParent(const GraphicsLayer& layer, const ScrollGeometries& geometries, bool withTransform = true)
{
    TransformationMatrix transform;
    auto position = layerPosition(layer, geometries);
    transform.translate(position.x(), position.y());
    if (withTransform)
        transform.multiply(anchoredTransform(layer));
    if (auto* parent = layer.parent(); parent && !parent->childrenTransform().isIdentity()) {
        FloatPoint3D anchor = parent->anchorPoint();
        anchor.scale(parent->size().width(), parent->size().height(), 1);
        anchor += layerBoundsOrigin(*parent, geometries);
        transform.translateRight3d(-anchor.x(), -anchor.y(), -anchor.z());
        transform = parent->childrenTransform() * transform;
        transform.translateRight3d(anchor.x(), anchor.y(), anchor.z());
    }
    auto boundsOrigin = layerBoundsOrigin(layer, geometries);
    transform.translate(-boundsOrigin.x(), -boundsOrigin.y());
    return transform;
}

static TransformationMatrix layerToRoot(const GraphicsLayer& layer, const ScrollGeometries& geometries)
{
    TransformationMatrix transform;
    for (auto* current = &layer; current->parent(); current = current->parent()) {
        auto step = layerToParent(*current, geometries);
        step.multiply(transform);
        transform = step;
    }
    return transform;
}

// Gaussian blurs compose into one whose variance is the sum of theirs.
static float blurDeviation(const FilterOperations& filters)
{
    float variance = 0;
    for (auto& operation : filters) {
        if (operation->type() == FilterOperation::Type::Blur) {
            float deviation = downcast<BlurFilterOperation>(operation.get()).stdDeviation();
            variance += deviation * deviation;
        }
    }
    return std::sqrt(variance);
}

namespace {

// A layer whose filters or mask change its colours, which the sampler does not render. Blurs it renders.
static bool hasUnrenderedEffects(const GraphicsLayer& layer)
{
    if (layer.maskLayer())
        return true;
    for (auto& operation : layer.filters()) {
        if (operation->type() != FilterOperation::Type::Blur)
            return true;
    }
    return false;
}

// Paints, in paint order, the backdrop root and every layer beneath `target` within it into `context`, whose
// transform maps root coordinates to the sample. Each layer's opacity and blend mode composite its content and
// sublayers as one group, as in Core Animation; a layer that draws a single primitive applies them to it
// directly. Layers whose opacity or transform animates paint as the animations have them now. Contents and effects
// it cannot paint are listed as unknown regions. Without a context it paints nothing and lists the layers it would
// paint, noting any whose content there changes in this commit, and any playing animation that reaches the sample.
class BeneathPainter {
public:
    BeneathPainter(const GraphicsLayer& target, GraphicsContext* context, const AffineTransform& rootToPixels, const IntSize& size, const ScrollGeometries& geometries)
        : m_target(target)
        , m_context(context)
        , m_rootToPixels(rootToPixels)
        , m_size(size)
        , m_geometries(geometries)
    {
    }

    void paint(const GraphicsLayer& backdropRoot, const FloatRect& clip)
    {
        TransformationMatrix parentToRoot;
        if (auto* parent = backdropRoot.parent())
            parentToRoot = layerToRoot(*parent, m_geometries);
        visit(backdropRoot, parentToRoot, clip, FloatRect::infiniteRect(), 1, true);
    }

    const Vector<FloatRect>& unknownRegions() const LIFETIME_BOUND { return m_unknownRegions; }
    bool foundChanges() const { return m_foundChanges; }
    bool foundPlayingAnimation() const { return m_foundPlayingAnimation; }
    Vector<BackdropSampler::Source> takeSources() { return WTF::move(m_sources); }

private:
    BackdropSampler::Source source(const GraphicsLayer& layer, PlatformLayerIdentifier identifier, const TransformationMatrix& toRoot, const FloatRect& bounds, float opacity, bool coversUnrendered)
    {
        return { identifier, toRoot, bounds, opacity, layer.masksToBounds(), layer.contentsAreVisible(), layer.blendMode(), coversUnrendered };
    }

    // A layer with effects the sampler does not render covers its whole subtree with an unknown region. Without
    // a context, the subtree's geometry is listed so that the region follows it.
    FloatRect coverUnrendered(const GraphicsLayer& layer, const TransformationMatrix& toRoot, float opacity)
    {
        FloatRect bounds { layerBoundsOrigin(layer, m_geometries), layerSize(layer, m_geometries) };
        FloatRect covered = toRoot.mapRect(bounds);
        if (!m_context) {
            if (auto identifier = layer.primaryLayerID())
                m_sources.append(source(layer, *identifier, toRoot, bounds, opacity, true));
        }
        for (auto& child : shownChildren(layer)) {
            TransformationMatrix childToRoot = toRoot;
            childToRoot.multiply(layerToParent(child, m_geometries));
            covered.unite(coverUnrendered(child, childToRoot, opacity * child->opacity()));
        }
        return covered;
    }

    // `clip` is where the layer's painting reaches the sample, within `masks`, its ancestors' clips.
    void visit(const GraphicsLayer& layer, const TransformationMatrix& parentToRoot, FloatRect clip, FloatRect masks, float opacity, bool isBackdropRoot)
    {
        if (&layer == &m_target) {
            m_reachedTarget = true;
            return;
        }
        TransformationMatrix toRoot = parentToRoot;
        if (layer.parent())
            toRoot.multiply(layerToParent(layer, m_geometries));
        FloatRect bounds { layerBoundsOrigin(layer, m_geometries), layerSize(layer, m_geometries) };
        if (!m_context && !isBackdropRoot && layer.playsOpacityOrTransformAnimation())
            noteAnimation(layer, parentToRoot, toRoot, clip);

        // The backdrop sees a backdrop root's content before the root's own opacity, blend mode, filters and
        // mask apply.
        float layerOpacity = 1;
        if (!isBackdropRoot) {
            layerOpacity = layer.opacity();
            if (layer.animatesOpacity())
                layer.client().getCurrentOpacity(&layer, layerOpacity);
        }
        if (layerOpacity <= 0)
            return;
        opacity *= layerOpacity;
        std::optional<FloatRect> ownMask;
        if (layer.masksToBounds())
            ownMask = toRoot.mapRect(bounds);
        if (!isBackdropRoot && hasUnrenderedEffects(layer)) {
            auto covered = intersection(coverUnrendered(layer, toRoot, opacity), ownMask ? intersection(clip, *ownMask) : clip);
            if (m_context)
                m_unknownRegions.append(covered);
            return;
        }

        // Content up to three standard deviations of a layer's blur outside the sample reaches into it.
        if (float deviation = isBackdropRoot ? 0 : blurDeviation(layer.filters()); deviation > 0) {
            auto layerToRoot = toRoot.toAffineTransform();
            auto reach = clip;
            reach.inflate(3 * deviation * std::max(layerToRoot.xScale(), layerToRoot.yScale()));
            reach.intersect(masks);
            if (m_context) {
                paintBlurred(layer, parentToRoot, toRoot, clip, reach, masks, opacity, layerOpacity, deviation);
                return;
            }
            clip = reach;
        }
        if (ownMask) {
            clip.intersect(*ownMask);
            masks.intersect(*ownMask);
            if (clip.isEmpty())
                return;
        }

        std::optional<FloatRect> localClip;
        if (toRoot.isInvertible()) {
            if (auto local = intersection(toRoot.inverse()->mapRect(clip), bounds); !local.isEmpty())
                localClip = local;
        }

        if (!m_context) {
            if (auto identifier = layer.primaryLayerID(); identifier && localClip) {
                m_sources.append(source(layer, *identifier, toRoot, bounds, opacity, false));
                m_foundChanges = m_foundChanges || (layer.contentsAreVisible() && layer.hasUncommittedContentChanges(*localClip));
            }
            for (auto& child : shownChildren(layer)) {
                visit(child, toRoot, clip, masks, opacity, false);
                if (m_reachedTarget)
                    return;
            }
            return;
        }

        auto& context = *m_context;
        bool blends = !isBackdropRoot && layer.blendMode() != BlendMode::Normal;
        bool drawsOwnContent = localClip && layer.contentsAreVisible();
        bool drawsOnePrimitive = shownChildren(layer).isEmpty() && !layer.drawsContent() && layer.backgroundColor().isVisible() != layer.usesContentsLayer();
        bool groups = (blends || layerOpacity < 1) && !drawsOnePrimitive;
        std::optional<GraphicsContextStateSaver> groupSaver;
        if (groups) {
            // Core Graphics sizes a transparency layer to the clip.
            groupSaver.emplace(context);
            context.clip(shownChildren(layer).isEmpty() ? intersection(toRoot.mapRect(bounds), clip) : clip);
            if (blends)
                context.beginTransparencyLayer(CompositeOperator::SourceOver, layer.blendMode());
            if (layerOpacity < 1)
                context.beginTransparencyLayer(layerOpacity);
        }

        // A layer whose contents are not visible draws none of its own content; its sublayers still draw.
        if (drawsOwnContent) {
            GraphicsContextStateSaver saver(context);
            if (!groups) {
                context.setAlpha(layerOpacity);
                context.setCompositeOperation(CompositeOperator::SourceOver, blends ? layer.blendMode() : BlendMode::Normal);
            }
            context.clip(clip);
            context.concatCTM(toRoot.toAffineTransform());
            if (layer.backgroundColor().isVisible())
                context.fillRect(bounds, layer.backgroundColor());
            if (layer.drawsContent())
                layer.paintGraphicsLayerContents(context, *localClip, GraphicsLayerPaintBehavior::DefaultAsynchronousImageDecode);
            if (!layer.paintContentsLayerForBackdropSampling(context))
                m_unknownRegions.append(intersection(toRoot.mapRect(intersection(layer.contentsRect(), layer.contentsClippingRect().rect())), clip));
        }

        for (auto& child : shownChildren(layer)) {
            visit(child, toRoot, clip, masks, opacity, false);
            if (m_reachedTarget)
                break;
        }

        if (groups) {
            if (layerOpacity < 1)
                context.endTransparencyLayer();
            if (blends)
                context.endTransparencyLayer();
        }
    }

    // The bounds of a layer and its sublayers, in root coordinates.
    FloatRect subtreeBounds(const GraphicsLayer& layer, const TransformationMatrix& toRoot)
    {
        FloatRect bounds = toRoot.mapRect(FloatRect { layerBoundsOrigin(layer, m_geometries), layerSize(layer, m_geometries) });
        for (auto& child : shownChildren(layer)) {
            TransformationMatrix childToRoot = toRoot;
            childToRoot.multiply(layerToParent(child, m_geometries));
            bounds.unite(subtreeBounds(child, childToRoot));
        }
        return bounds;
    }

    // A playing animation reaches the sample when what it changes does: the bounds the layer and its sublayers
    // sweep, or for an opacity animation its subtree, grown by the reach of the layer's blur.
    void noteAnimation(const GraphicsLayer& layer, const TransformationMatrix& parentToRoot, const TransformationMatrix& toRoot, const FloatRect& clip)
    {
        FloatRect reached = subtreeBounds(layer, toRoot);
        if (auto extent = layer.animationExtent()) {
            TransformationMatrix extentToRoot = parentToRoot;
            extentToRoot.multiply(layerToParent(layer, m_geometries, false));
            reached.unite(extentToRoot.mapRect(*extent));
        }
        if (float deviation = blurDeviation(layer.filters()); deviation > 0) {
            auto layerToRoot = toRoot.toAffineTransform();
            reached.inflate(3 * deviation * std::max(layerToRoot.xScale(), layerToRoot.yScale()));
        }
        m_foundPlayingAnimation = m_foundPlayingAnimation || reached.intersects(clip);
    }

    // Paints a layer with blur filters, without its effects as a backdrop root paints, within `reach` into a
    // buffer of its own that extends the sample by the blur's reach. It blurs that at the sample's scale and
    // composites it within `clip` with the layer's opacity and blend mode.
    void paintBlurred(const GraphicsLayer& layer, const TransformationMatrix& parentToRoot, const TransformationMatrix& toRoot, const FloatRect& clip, const FloatRect& reach, const FloatRect& masks, float opacity, float layerOpacity, float deviation)
    {
        auto& context = *m_context;
        auto pixelsToRoot = m_rootToPixels.inverse();
        if (!pixelsToRoot)
            return;
        auto layerToPixels = m_rootToPixels * toRoot.toAffineTransform();
        FloatSize pixelDeviation { deviation * static_cast<float>(layerToPixels.xScale()), deviation * static_cast<float>(layerToPixels.yScale()) };
        int margin = std::ceil(3 * std::max(pixelDeviation.width(), pixelDeviation.height()));
        IntSize size = m_size + IntSize { 2 * margin, 2 * margin };
        RefPtr buffer = ImageBuffer::create(size, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, DestinationColorSpace::SRGB(), PixelFormat::BGRA8);
        if (!buffer)
            return;
        AffineTransform rootToLayerPixels;
        rootToLayerPixels.translate(margin, margin);
        rootToLayerPixels.multiply(m_rootToPixels);
        auto& layerContext = buffer->context();
        layerContext.setImageInterpolationQuality(context.imageInterpolationQuality());
        layerContext.concatCTM(rootToLayerPixels);
        {
            SetForScope contextScope(m_context, &layerContext);
            SetForScope transformScope(m_rootToPixels, rootToLayerPixels);
            SetForScope sizeScope(m_size, size);
            visit(layer, parentToRoot, reach, masks, opacity, true);
        }

        Vector<Ref<FilterFunction>> functions;
        functions.append(FEGaussianBlur::create(pixelDeviation.width(), pixelDeviation.height(), EdgeModeType::None));
        FloatRect region { { }, size };
        auto filter = CSSFilterRenderer::create(WTF::move(functions), FilterGeometry { region, region, { 1, 1 } }, FilterRenderingMode::Software, { });
        FilterResults results;
        GraphicsContextStateSaver saver(context);
        context.clip(clip);
        context.concatCTM(*pixelsToRoot);
        context.translate(-margin, -margin);
        context.setAlpha(layerOpacity);
        context.setCompositeOperation(CompositeOperator::SourceOver, layer.blendMode());
        context.drawFilteredImageBuffer(buffer.get(), region, filter, results);
    }

    const GraphicsLayer& m_target;
    GraphicsContext* m_context;
    AffineTransform m_rootToPixels;
    IntSize m_size;
    const ScrollGeometries& m_geometries;
    Vector<FloatRect> m_unknownRegions;
    Vector<BackdropSampler::Source> m_sources;
    bool m_reachedTarget { false };
    bool m_foundChanges { false };
    bool m_foundPlayingAnimation { false };
};

}

BackdropSampler::BackdropSampler(Function<void()>&& scheduleRenderingUpdate)
    : m_scheduleRenderingUpdate(WTF::move(scheduleRenderingUpdate))
    , m_timer([this] { m_scheduleRenderingUpdate(); })
{
}

void BackdropSampler::sampleBackdrop(GraphicsLayer& root, GraphicsLayer& target, const FloatRect& visibleRect, const Color& viewBackground, const ScrollGeometries& geometries, HashMap<PlatformLayerIdentifier, State>& states)
{
    auto targetIdentifier = target.primaryLayerID();
    if (!targetIdentifier)
        return;

    // The image is painted in the backdrop layer's coordinates. A backdrop without a blur shows its fill.
    auto backdropRect = target.backdropFiltersRect().rect();
    FloatRect bounds { { }, backdropRect.size() };
    auto backdropToRoot = layerToRoot(target, geometries);
    backdropToRoot.translate(backdropRect.x(), backdropRect.y());
    auto rootToBackdrop = backdropToRoot.inverse();
    // The image holds what the smallest blur the chain animates through shows, and reaches as far as its largest.
    float minimumDeviation = blurDeviation(target.backdropFilters()), maximumDeviation = minimumDeviation;
    for (auto& keyframe : target.backdropFilterAnimationKeyframes()) {
        float deviation = blurDeviation(keyframe);
        minimumDeviation = std::min(minimumDeviation, deviation);
        maximumDeviation = std::max(maximumDeviation, deviation);
    }
    auto rect = backdropToRoot.mapRect(bounds);
    if (rect.isEmpty() || !rootToBackdrop || maximumDeviation < minimumSampledDeviation) {
        target.setBackdropSample(nullptr, { });
        return;
    }

    // A backdrop sees up to its nearest backdrop-root ancestor, clipped as that ancestor is and to the view.
    GraphicsLayer* backdropRoot = &root;
    for (auto* ancestor = target.parent(); ancestor; ancestor = ancestor->parent()) {
        if (ancestor->isBackdropRoot()) {
            backdropRoot = ancestor;
            break;
        }
    }
    FloatRect clip = intersection(rect, visibleRect);
    for (auto* ancestor = backdropRoot->parent(); ancestor; ancestor = ancestor->parent()) {
        if (ancestor->masksToBounds())
            clip.intersect(layerToRoot(*ancestor, geometries).mapRect(FloatRect { layerBoundsOrigin(*ancestor, geometries), layerSize(*ancestor, geometries) }));
    }
    Color base = backdropRoot == &root ? viewBackground : Color::transparentBlack;

    // The image changes only when what it is painted from does.
    BeneathPainter finder(target, nullptr, { }, { }, geometries);
    if (!clip.isEmpty())
        finder.paint(*backdropRoot, clip);
    Inputs current { backdropToRoot, bounds.size(), minimumDeviation, maximumDeviation, clip, backdropRoot->primaryLayerID(), base, finder.takeSources() };
    auto previous = m_states.find(*targetIdentifier);
    bool changed = finder.foundChanges() || previous == m_states.end() || previous->value.pending || *previous->value.inputs != current;
    State state { makeUnique<Inputs>(WTF::move(current)), previous == m_states.end() ? MonotonicTime { } : previous->value.painted };
    auto now = MonotonicTime::now();
    if (changed) {
        if (auto wait = state.painted + minimumPaintInterval - now; wait > 0_s) {
            state.pending = true;
            changed = false;
            if (!m_timer.isActive() || m_timer.nextFireInterval() > wait)
                m_timer.startOneShot(wait);
        } else
            state.painted = now;
    }
    // Core Animation changes a layer whose opacity or transform animation plays without a rendering update, so
    // while one reaches the sample, or moves the backdrop, the sampler looks again each interval.
    bool animationPlays = finder.foundPlayingAnimation();
    for (auto* layer = &target; layer && !animationPlays; layer = layer->parent())
        animationPlays = layer->playsOpacityOrTransformAnimation();
    if (animationPlays && !m_timer.isActive())
        m_timer.startOneShot(minimumPaintInterval);
    states.set(*targetIdentifier, WTF::move(state));
    if (!changed)
        return;

    // The image covers what the view shows of the backdrop and the blur's reach around it. A backdrop the view
    // does not show keeps its image.
    auto visible = intersection(rootToBackdrop->mapRect(clip), bounds);
    if (visible.isEmpty())
        return;
    auto sampleRect = visible;
    sampleRect.inflate(3 * maximumDeviation);
    sampleRect.intersect(bounds);
    float scale = std::min({ 1.f, maximumSampleLength / std::max(sampleRect.width(), sampleRect.height()) });
    if (minimumDeviation > 0)
        scale = std::min(scale, pixelsPerDeviation / minimumDeviation);
    IntSize size { std::max(1, static_cast<int>(std::ceil(sampleRect.width() * scale))), std::max(1, static_cast<int>(std::ceil(sampleRect.height() * scale))) };
    sampleRect.setSize(FloatSize { size } / scale);
    RefPtr buffer = ImageBuffer::create(size, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, DestinationColorSpace::SRGB(), PixelFormat::BGRA8);
    if (!buffer)
        return;
    auto& context = buffer->context();
    // The blur hides the difference high-quality resampling of the images painted into it would make.
    context.setImageInterpolationQuality(InterpolationQuality::Low);
    AffineTransform rootToPixels;
    rootToPixels.scale(scale);
    rootToPixels.translate(-sampleRect.x(), -sampleRect.y());
    rootToPixels.multiply(rootToBackdrop->toAffineTransform());
    context.concatCTM(rootToPixels);
    context.fillRect(clip, base);
    BeneathPainter painter(target, &context, rootToPixels, size, geometries);
    painter.paint(*backdropRoot, clip);
    for (auto& region : painter.unknownRegions())
        context.clearRect(region);

    // Beyond what the view shows, the image repeats the pixels at its edge, as the blur clamps at the view's.
    auto pixel = [&](float coordinate, float origin) {
        return (coordinate - origin) * scale;
    };
    int left = std::clamp(static_cast<int>(std::ceil(pixel(visible.x(), sampleRect.x()))), 0, size.width() - 1);
    int top = std::clamp(static_cast<int>(std::ceil(pixel(visible.y(), sampleRect.y()))), 0, size.height() - 1);
    int right = std::clamp(static_cast<int>(std::floor(pixel(visible.maxX(), sampleRect.x()))), left + 1, size.width());
    int bottom = std::clamp(static_cast<int>(std::floor(pixel(visible.maxY(), sampleRect.y()))), top + 1, size.height());
    if (left || top || right < size.width() || bottom < size.height()) {
        IntRect whole { { }, size };
        RefPtr pixels = buffer->getPixelBuffer({ AlphaPremultiplication::Premultiplied, PixelFormat::BGRA8, DestinationColorSpace::SRGB() }, whole);
        if (!pixels)
            return;
        auto bytes = pixels->bytes();
        for (int y = 0; y < size.height(); ++y) {
            int sourceY = std::clamp(y, top, bottom - 1);
            for (int x = 0; x < size.width(); ++x) {
                int sourceX = std::clamp(x, left, right - 1);
                if (sourceX != x || sourceY != y)
                    memcpySpan(bytes.subspan((static_cast<size_t>(y) * size.width() + x) * 4, 4), bytes.subspan((static_cast<size_t>(sourceY) * size.width() + sourceX) * 4, 4));
            }
        }
        buffer->putPixelBuffer(*pixels, whole);
    }

    if (RefPtr image = ImageBuffer::sinkIntoNativeImage(WTF::move(buffer)))
        target.setBackdropSample(WTF::move(image), sampleRect);
}

// A layer whose contents are not visible hides its backdrop layer, and a transparent layer whose opacity does not
// animate hides its subtree.
static void collectBackdropLayers(GraphicsLayer& layer, Vector<Ref<GraphicsLayer>>& layers)
{
    if (layer.opacity() <= 0 && !layer.animatesOpacity())
        return;
    if (!layer.backdropFilters().isEmpty() && layer.contentsAreVisible())
        layers.append(layer);
    for (auto& child : shownChildren(layer))
        collectBackdropLayers(child, layers);
}

void BackdropSampler::sample(GraphicsLayer& root, const FloatRect& visibleRect, const Color& viewBackground, NOESCAPE const Function<ScrollGeometries()>& scrollGeometries)
{
    Vector<Ref<GraphicsLayer>> layers;
    collectBackdropLayers(root, layers);
    HashMap<PlatformLayerIdentifier, State> states;
    if (!layers.isEmpty()) {
        auto geometries = scrollGeometries();
        for (auto& layer : layers)
            sampleBackdrop(root, layer, visibleRect, viewBackground, geometries, states);
    }
    m_states = WTF::move(states);
}

}
