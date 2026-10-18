# A new stacking context and the 3D descendant cache

Each page shows two scenes that should match: the left one changes after it first renders, the right one
has the final style from the start.

- `perspective-stacking-context.html`: the left parent changes from `perspective: none` to `500px`.
- `transform-style-stacking-context.html`: the left scene changes from `transform-style: flat` to
  `preserve-3d` inside a preserve-3d parent with perspective.

`RenderLayerCompositor::computeIndirectCompositingReason` selects perspective and preserve-3d
compositing using `RenderLayer::has3DTransformedDescendant()`. That cached value is computed from the
positive and negative z-order lists, so a layer that is not a stacking context caches false.

- `dirtyZOrderLists()` does not invalidate it when perspective creates a stacking context, so the
  parent can retain a false value and lack a perspective backing layer.
- `RenderLayer::styleChanged` calls `dirty3DTransformedDescendantStatus()` when `transform-style`
  changes, and that marks the layer's stacking context and its preserve-3d ancestors but not the layer
  itself. The scene keeps the false value it cached while flat, its parent sees no 3D descendant, and
  neither composites: the GraphicsLayer tree holds the transformed children flattened under the root.
  A scene that is already a stacking context while flat (for example `z-index: 0`) caches the true
  value and renders correctly after the change.

[Upstream change 285632@main](https://github.com/WebKit/WebKit/commit/09fa4e566b17a4001771f00cad52f312b88132f1)
uses this cache for compositing decisions. The rendering code responsible for the cache and its
invalidation matches upstream. This diagnosis comes from source inspection and reproduction on
Mavericks; current Safari has not been tested.
