/*
 * Copyright (C) 2026 Igalia S.L
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// Accelerated <video> compositing for the Cocoa+GStreamer hybrid. The upstream
// GStreamer player only has an accelerated frame path under USE(COORDINATED_GRAPHICS) (texture
// mapper), which this CoreGraphics/CoreAnimation build doesn't use. These helpers back
// MediaPlayerPrivateGStreamer::platformLayer() with a plain CALayer whose contents are updated
// per-frame from the GStreamer streaming thread, so decoded frames reach the screen through the
// compositor instead of the main-thread tile-repaint path.

#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)

#include "GRefPtrGStreamer.h"
#include "ImageOrientation.h"
#include <wtf/RetainPtr.h>

typedef struct _GstSample GstSample;
OBJC_CLASS CALayer;

namespace WebCore {

// Must be called on the main thread.
RetainPtr<CALayer> createGStreamerVideoLayer();

// Thread-safe: wraps the layer mutation in an explicit CATransaction, so it may be called from the
// GStreamer streaming thread. The sample's buffer must be a mapped-readable system-memory RGB frame
// (the formats the WebKit fallback video sink negotiates). A non-identity source orientation is
// baked into the pixels (the layer itself carries no geometry transform — a layer transform fights
// GraphicsLayerCA's bounds/anchor), so streams of every orientation composite here.
void setGStreamerVideoLayerContents(CALayer*, const GRefPtr<GstSample>&, ImageOrientation);

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA) && !USE(COORDINATED_GRAPHICS)
