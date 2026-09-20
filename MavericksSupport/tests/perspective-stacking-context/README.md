# Dynamic perspective and the 3D descendant cache

Open `perspective-stacking-context.html`. Both scenes should have the same projection.
The left parent changes from `perspective: none` to `500px`; the right parent has
perspective from the start.

`RenderLayerCompositor::computeIndirectCompositingReason` selects perspective
compositing using `RenderLayer::has3DTransformedDescendant()`. That cached value is
computed from the positive and negative z-order lists. `dirtyZOrderLists()` does
not invalidate it when perspective creates a stacking context, so the parent can
retain a false value and lack a perspective backing layer.

[Upstream change 285632@main](https://github.com/WebKit/WebKit/commit/09fa4e566b17a4001771f00cad52f312b88132f1)
uses this cache for compositing decisions. The rendering code responsible for the
cache and its invalidation matches upstream. This diagnosis comes from source
inspection and reproduction on Mavericks; current Safari has not been tested.
