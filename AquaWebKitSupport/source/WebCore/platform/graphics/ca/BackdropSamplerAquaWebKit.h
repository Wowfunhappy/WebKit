#pragma once

#include "Color.h"
#include "FloatRect.h"
#include "GraphicsTypes.h"
#include "PlatformLayerIdentifier.h"
#include "Timer.h"
#include "TransformationMatrix.h"
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

namespace WebCore {

class GraphicsLayer;

// Gives each displayed layer with blurring backdrop filters under a root an image of the content painted beneath
// its backdrop rect, up to its backdrop root, and repaints it when that content changes, at most once per 100 ms.
// A change within that time of the last image is painted once it has passed, in a rendering update the sampler
// schedules.
class BackdropSampler {
    WTF_MAKE_TZONE_ALLOCATED(BackdropSampler);
public:
    explicit BackdropSampler(Function<void()>&& scheduleRenderingUpdate);

    // Where scrolled layers sit at the scroll positions being committed, overriding their GraphicsLayers.
    struct ScrollGeometry {
        std::optional<FloatPoint> position;
        std::optional<FloatPoint> boundsOrigin;
        std::optional<FloatSize> size;
    };
    using ScrollGeometries = HashMap<const GraphicsLayer*, ScrollGeometry>;

    // `visibleRect`, in `root`'s coordinates, is what the view shows; `viewBackground` shows where nothing is
    // painted when the backdrop root is `root`. `scrollGeometries` is asked for only when there are backdrops.
    void sample(GraphicsLayer& root, const FloatRect& visibleRect, const Color& viewBackground, NOESCAPE const Function<ScrollGeometries()>& scrollGeometries);

    // A layer the samples are painted from, with every property of it the painting reads.
    struct Source {
        PlatformLayerIdentifier layer;
        TransformationMatrix toRoot;
        FloatRect bounds;
        float opacity;
        bool masksToBounds;
        bool contentsVisible;
        BlendMode blendMode;
        bool coversUnrendered;
        friend bool operator==(const Source&, const Source&) = default;
    };

    // Everything a backdrop's image is painted from.
    struct Inputs {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(Inputs);
        TransformationMatrix backdropToRoot;
        FloatSize size;
        float minimumDeviation;
        float maximumDeviation;
        FloatRect clip;
        std::optional<PlatformLayerIdentifier> backdropRoot;
        Color viewBackground;
        Vector<Source> sources;
        friend bool operator==(const Inputs&, const Inputs&) = default;
    };

private:
    struct State {
        std::unique_ptr<Inputs> inputs;
        MonotonicTime painted;
        bool pending { false };
    };

    void sampleBackdrop(GraphicsLayer& root, GraphicsLayer& target, const FloatRect& visibleRect, const Color& viewBackground, const ScrollGeometries&, HashMap<PlatformLayerIdentifier, State>&);

    HashMap<PlatformLayerIdentifier, State> m_states;
    Function<void()> m_scheduleRenderingUpdate;
    Timer m_timer;
};

}
