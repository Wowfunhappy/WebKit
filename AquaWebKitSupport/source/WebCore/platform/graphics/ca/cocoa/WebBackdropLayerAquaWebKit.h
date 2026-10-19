#pragma once

#include "PlatformExportMacros.h"
#import <QuartzCore/QuartzCore.h>

// WebKit's stand-in for CABackdropLayer, built on CALayer.backgroundFilters: its filters apply to the backdrop.
//
// 10.9 background filters read only the nearest ancestor that is not a CATransformLayer: the layer's sampling
// surface. A blur with hard edges reads only the rect that the layer's bounds give in the surface's coordinates, less
// its outermost pixels. The layer crops its blur to its footprint there: its bounds are the footprint's bounding box
// in the surface, one pixel larger, and a mask at the bounds origin carries the shape the layer presents. The
// presented bounds, mask, corner radius and masksToBounds are what callers set and read. Independent opacity()
// functions filter the coverage mask's alpha.
//
// A sampling-surface instance draws, just before a layer that is a separate surface, the same filters over the
// pixels behind that layer. Its mask reproduces the layers between it and the backdrop layer it serves.
WEBCORE_EXPORT @interface WebBackdropLayerAquaWebKit : CALayer

// The background filters as set. -backgroundFilters returns them as the layer adapts them, while it is rendered.
- (NSArray *)assignedBackgroundFilters;

// path: the layers between `boundary` and `backdropLayer`, outermost first.
- (void)updateSamplingSurfaceWithBoundary:(CALayer *)boundary path:(NSArray *)path backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer;

// For a replica's copy: the path is the layer tree's, from `backdropLayer` up to `boundary`. The layer keeps neither,
// and -updateSamplingSurfaceFromLayerTree repeats the update while both exist.
- (void)updateSamplingSurfaceWithBoundary:(CALayer *)boundary backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer;
- (void)updateSamplingSurfaceFromLayerTree;
- (WebBackdropLayerAquaWebKit *)samplingSurfaceBackdropLayer;

// The rect of its sampling surface this layer's filters read, in the surface's coordinates, over its animations: its
// crop, or without one its footprint. CGRectNull when it reads nothing; false when that is not known.
- (BOOL)getSampleRegion:(CGRect *)region;

// Whether the surface this layer samples is the backdrop root's.
- (void)setSamplesBackdropRoot:(BOOL)samplesBackdropRoot;

// layers: the ancestors of `backdropLayer`, from its superlayer up to at least the surface this layer samples.
// parentIndex: the index of this layer's superlayer among them, NSNotFound for the current superlayer.
- (void)setCropLayers:(NSArray *)layers parentIndex:(NSUInteger)parentIndex backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer;

@end

// The extent of `layer` in its sampling surface through the planned ancestors, innermost first, including
// transform hosts and their animations. False when the chain ends before an ordinary sampling surface.
WEBCORE_EXPORT bool WebBackdropLayerAquaWebKitExtentInSamplingSurface(CALayer *, NSArray *ancestors, CGRect* extent);

// The pixels of the nearest ordinary sampling surface that `layer`'s background filters, or those in the
// transform layers below it, read. CGRectNull when none read it; false when that is not known.
WEBCORE_EXPORT bool WebBackdropLayerAquaWebKitSampleRegionInSuperlayer(CALayer *, CGRect* region);

// Crops again the layers whose sampling surface was outside the host's tree when they last cropped, now that a
// layer tree commit has built it.
WEBCORE_EXPORT void WebBackdropLayerAquaWebKitLayerTreeDidCommit();

// Carries the contents `layer` has displayed to the sampling-surface layers' copies of it.
WEBCORE_EXPORT void WebBackdropLayerAquaWebKitContentsDidChange(CALayer *);

// Carries a position or bounds change made outside a layer tree commit (by the scrolling thread) to the
// sampling-surface layers that reproduce the layer and the crops that depend on it.
WEBCORE_EXPORT void WebBackdropLayerAquaWebKitGeometryDidChange(CALayer *);
