#include "config.h"
#include "BackdropSamplerAquaWebKit.h"

#include "Color.h"
#include "FilterOperations.h"
#include "FloatQuad.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "ImageBuffer.h"
#include "PixelBuffer.h"
#include "TransformationMatrix.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(BackdropSampler);

// The content beneath a backdrop is painted at a scale that makes its longer side this many pixels, and
// averaged into up to this many bands along that side.
static constexpr float sampleResolution = 128;
static constexpr unsigned maximumBands = 8;

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

static TransformationMatrix anchoredTransform(const GraphicsLayer& layer)
{
    const auto& matrix = layer.transform();
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

// Maps a point in `layer`'s bounds coordinates into its parent's, as GraphicsLayerCA lays layers out.
static TransformationMatrix layerToParent(const GraphicsLayer& layer, const ScrollGeometries& geometries)
{
    TransformationMatrix transform;
    auto position = layerPosition(layer, geometries);
    transform.translate(position.x(), position.y());
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

namespace {

// A layer whose filters or mask change its colours, which the sampler does not render. Blur keeps a layer's
// average colour, so a filter chain of blurs paints unfiltered.
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
// directly. Contents and effects it cannot paint are recorded as unknown regions. Without a context it paints
// nothing and lists the layers it would paint, noting any whose content there changes in this commit.
class BeneathPainter {
public:
    BeneathPainter(const GraphicsLayer& target, GraphicsContext* context, const ScrollGeometries& geometries)
        : m_target(target)
        , m_context(context)
        , m_geometries(geometries)
    {
    }

    void paint(const GraphicsLayer& backdropRoot, const FloatRect& clip)
    {
        TransformationMatrix parentToRoot;
        if (auto* parent = backdropRoot.parent())
            parentToRoot = layerToRoot(*parent, m_geometries);
        visit(backdropRoot, parentToRoot, clip, 1, true);
    }

    const Vector<FloatRect>& unknownRegions() const { return m_unknownRegions; }
    bool foundChanges() const { return m_foundChanges; }
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
        for (auto& child : layer.children()) {
            TransformationMatrix childToRoot = toRoot;
            childToRoot.multiply(layerToParent(child, m_geometries));
            covered.unite(coverUnrendered(child, childToRoot, opacity * child->opacity()));
        }
        return covered;
    }

    void visit(const GraphicsLayer& layer, const TransformationMatrix& parentToRoot, FloatRect clip, float opacity, bool isBackdropRoot)
    {
        if (&layer == &m_target) {
            m_reachedTarget = true;
            return;
        }
        // The backdrop sees a backdrop root's content before the root's own opacity, blend mode, filters and
        // mask apply.
        float layerOpacity = isBackdropRoot ? 1 : layer.opacity();
        if (layerOpacity <= 0)
            return;
        opacity *= layerOpacity;

        TransformationMatrix toRoot = parentToRoot;
        if (layer.parent())
            toRoot.multiply(layerToParent(layer, m_geometries));
        FloatRect bounds { layerBoundsOrigin(layer, m_geometries), layerSize(layer, m_geometries) };
        if (layer.masksToBounds()) {
            clip.intersect(toRoot.mapRect(bounds));
            if (clip.isEmpty())
                return;
        }
        if (!isBackdropRoot && hasUnrenderedEffects(layer)) {
            auto covered = intersection(coverUnrendered(layer, toRoot, opacity), clip);
            if (m_context)
                m_unknownRegions.append(covered);
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
            for (auto& child : layer.children()) {
                visit(child, toRoot, clip, opacity, false);
                if (m_reachedTarget)
                    return;
            }
            return;
        }

        auto& context = *m_context;
        bool blends = !isBackdropRoot && layer.blendMode() != BlendMode::Normal;
        bool drawsOwnContent = localClip && layer.contentsAreVisible();
        bool drawsOnePrimitive = layer.children().isEmpty() && !layer.drawsContent() && layer.backgroundColor().isVisible() != layer.usesContentsLayer();
        bool groups = (blends || layerOpacity < 1) && !drawsOnePrimitive;
        std::optional<GraphicsContextStateSaver> groupSaver;
        if (groups) {
            // Core Graphics sizes a transparency layer to the clip.
            groupSaver.emplace(context);
            context.clip(layer.children().isEmpty() ? intersection(toRoot.mapRect(bounds), clip) : clip);
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
                m_unknownRegions.append(intersection(toRoot.mapRect(layer.contentsRect()), clip));
        }

        for (auto& child : layer.children()) {
            visit(child, toRoot, clip, opacity, false);
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

    const GraphicsLayer& m_target;
    GraphicsContext* m_context;
    const ScrollGeometries& m_geometries;
    Vector<FloatRect> m_unknownRegions;
    Vector<BackdropSampler::Source> m_sources;
    bool m_reachedTarget { false };
    bool m_foundChanges { false };
};

}

void BackdropSampler::sampleBackdrop(GraphicsLayer& root, GraphicsLayer& target, const FloatRect& visibleRect, const Color& viewBackground, const ScrollGeometries& geometries, HashMap<PlatformLayerIdentifier, Inputs>& inputs)
{
    auto targetIdentifier = target.primaryLayerID();
    if (!targetIdentifier)
        return;

    auto rect = layerToRoot(target, geometries).mapRect(target.backdropFiltersRect().rect());
    if (rect.isEmpty())
        return;

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

    // The samples change only when what they are painted from does.
    BeneathPainter finder(target, nullptr, geometries);
    if (!clip.isEmpty())
        finder.paint(*backdropRoot, clip);
    Inputs current { rect, clip, backdropRoot->primaryLayerID(), base, finder.takeSources() };
    auto previous = m_inputs.find(*targetIdentifier);
    bool changed = finder.foundChanges() || previous == m_inputs.end() || previous->value != current;
    inputs.set(*targetIdentifier, WTF::move(current));
    if (!changed)
        return;

    float scale = sampleResolution / std::max(rect.width(), rect.height());
    IntSize size { std::max(1, static_cast<int>(std::ceil(rect.width() * scale))), std::max(1, static_cast<int>(std::ceil(rect.height() * scale))) };
    RefPtr buffer = ImageBuffer::create(size, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, DestinationColorSpace::SRGB(), PixelFormat::BGRA8);
    if (!buffer)
        return;
    auto& context = buffer->context();
    // An average needs no high-quality resampling of the images painted into it. Only the backdrop's visible
    // part has content, so the rest of the sample stays transparent and carries no weight.
    context.setImageInterpolationQuality(InterpolationQuality::Low);
    context.scale(scale);
    context.translate(-rect.x(), -rect.y());
    context.fillRect(clip, base);
    BeneathPainter painter(target, &context, geometries);
    if (!clip.isEmpty())
        painter.paint(*backdropRoot, clip);

    RefPtr pixels = buffer->getPixelBuffer({ AlphaPremultiplication::Premultiplied, PixelFormat::RGBA8, DestinationColorSpace::SRGB() }, IntRect { { }, size });
    if (!pixels)
        return;

    bool vertical = size.height() > size.width();
    int along = vertical ? size.height() : size.width(), across = vertical ? size.width() : size.height();
    unsigned bands = std::clamp<unsigned>(std::round(static_cast<float>(along) / across), 1, maximumBands);
    Vector<std::optional<Color>> colors;
    for (unsigned band = 0; band < bands; ++band) {
        int start = along * band / bands, end = std::max(start + 1, static_cast<int>(along * (band + 1) / bands));
        FloatRect bandRect = vertical
            ? FloatRect { rect.x(), rect.y() + start / scale, rect.width(), (end - start) / scale }
            : FloatRect { rect.x() + start / scale, rect.y(), (end - start) / scale, rect.height() };
        if (std::ranges::any_of(painter.unknownRegions(), [&](auto& region) { return region.intersects(bandRect); })) {
            colors.append(std::nullopt);
            continue;
        }
        // Coverage counts the visible pixels only.
        double sum[4] = { 0, 0, 0, 0 }, count = 0;
        for (int a = start; a < end; ++a) {
            for (int c = 0; c < across; ++c) {
                int x = vertical ? c : a, y = vertical ? a : c;
                if (!clip.contains(FloatPoint { rect.x() + (x + .5f) / scale, rect.y() + (y + .5f) / scale }))
                    continue;
                ++count;
                size_t offset = (static_cast<size_t>(y) * size.width() + x) * 4;
                for (int i = 0; i < 4; ++i)
                    sum[i] += pixels->item(offset + i);
            }
        }
        auto channel = [&](int i) {
            return static_cast<uint8_t>(std::lround(sum[3] > 0 ? 255 * sum[i] / sum[3] : 0));
        };
        colors.append(Color { SRGBA<uint8_t> { channel(0), channel(1), channel(2), static_cast<uint8_t>(count ? std::lround(sum[3] / count) : 0) } });
    }
    target.setBackdropSamples(WTF::move(colors), vertical);
}

// A layer whose contents are not visible hides its backdrop layer.
static void collectBackdropLayers(GraphicsLayer& layer, Vector<Ref<GraphicsLayer>>& layers)
{
    if (!layer.backdropFilters().isEmpty() && layer.contentsAreVisible())
        layers.append(layer);
    for (auto& child : layer.children())
        collectBackdropLayers(child, layers);
}

void BackdropSampler::sample(GraphicsLayer& root, const FloatRect& visibleRect, const Color& viewBackground, NOESCAPE const Function<ScrollGeometries()>& scrollGeometries)
{
    Vector<Ref<GraphicsLayer>> layers;
    collectBackdropLayers(root, layers);
    HashMap<PlatformLayerIdentifier, Inputs> inputs;
    if (!layers.isEmpty()) {
        auto geometries = scrollGeometries();
        for (auto& layer : layers)
            sampleBackdrop(root, layer, visibleRect, viewBackground, geometries, inputs);
    }
    m_inputs = WTF::move(inputs);
}

}
