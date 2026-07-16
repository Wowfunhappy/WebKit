/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#include "config.h"
#include "ANGLEUtilitiesCocoa.h"

#if ENABLE(WEBGL)
#include "ANGLEHeaders.h"
#include "ANGLEUtilities.h"
#include "Logging.h"
// MAVERICKS_BACKPORT: Metal (10.11+) is unavailable on 10.9; this build uses ANGLE's OpenGL/CGL
// backend. The deployment target, not the SDK, decides whether Metal exists at RUNTIME, so this
// MUST key on MIN_REQUIRED (=1090 here), NOT MAX_ALLOWED. Under the 26.1 SDK MAX_ALLOWED is huge
// and always-true, which would wrongly select the Metal backend and weak-link to NULL on 10.9.
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
#define WK_ANGLE_METAL 1
#else
#define WK_ANGLE_METAL 0
#endif
#if WK_ANGLE_METAL
#include <Metal/Metal.h>
#include <pal/spi/cocoa/MetalSPI.h>
// MAVERICKS_BACKPORT: Metal headers compiled in only when WK_ANGLE_METAL (Metal is 10.11+, absent on 10.9).
#endif
#include <wtf/SoftLinking.h>
#include <wtf/StdLibExtras.h>
#include <wtf/darwin/WeakLinking.h>

#if USE(APPLE_INTERNAL_SDK) && PLATFORM(VISION)
#include <CompositorServices/CompositorServices_Private.h>

SOFT_LINK_FRAMEWORK_FOR_SOURCE(WebCore, CompositorServices)

SOFT_LINK_CLASS_FOR_HEADER(WebCore, CP_OBJECT_cp_proxy_process_rasterization_rate_map)
typedef CP_OBJECT_cp_proxy_process_rasterization_rate_map* cp_proxy_process_rasterization_rate_map_t;

SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_create, cp_proxy_process_rasterization_rate_map_t, (id<MTLDevice> device, cp_layer_renderer_layout layout, size_t view_count), (device, layout, view_count))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_create, cp_proxy_process_rasterization_rate_map_t, (id<MTLDevice> device, cp_layer_renderer_layout layout, size_t view_count), (device, layout, view_count))
#define cp_proxy_process_rasterization_rate_map_create softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_create


SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_rasterization_rate_map_update_shared_from_layered_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, MTLRasterizationRateMapDescriptor* descriptor), (proxy_map, descriptor))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_rasterization_rate_map_update_shared_from_layered_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, MTLRasterizationRateMapDescriptor* descriptor), (proxy_map, descriptor))
#define cp_rasterization_rate_map_update_shared_from_layered_descriptor softLink_CompositorServices_cp_rasterization_rate_map_update_shared_from_layered_descriptor


// MAVERICKS_BACKPORT: return type reduced to plain NSArray * (the MTLRasterizationRateMap protocol is Metal/10.11+, absent here).
SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_maps, NSArray *>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_maps, NSArray *>*, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
#define cp_proxy_process_rasterization_rate_map_get_metal_maps softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_maps


// MAVERICKS_BACKPORT: return type reduced to plain NSArray * (MTLRasterizationRateMapDescriptor is Metal/10.11+, absent here).
SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_descriptors, NSArray **, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))
SOFT_LINK_FUNCTION_FOR_HEADER(WebCore, CompositorServices, cp_rasterization_rate_map_update_from_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, __unsafe_unretained MTLRasterizationRateMapDescriptor* descriptors[2]), (proxy_map, descriptors))
SOFT_LINK_CLASS_FOR_SOURCE_OPTIONAL(WebCore, CompositorServices, CP_OBJECT_cp_proxy_process_rasterization_rate_map)

SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_drawable_get_layer_renderer_layout, cp_layer_renderer_layout_private, (cp_drawable_t drawable), (drawable))

// MAVERICKS_BACKPORT: return type reduced to plain NSArray * (MTLRasterizationRateMapDescriptor is Metal/10.11+, absent here).
SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_proxy_process_rasterization_rate_map_get_metal_descriptors, NSArray **, (cp_proxy_process_rasterization_rate_map_t proxy_map), (proxy_map))

SOFT_LINK_FUNCTION_FOR_SOURCE(WebCore, CompositorServices, cp_rasterization_rate_map_update_from_descriptor, void, (cp_proxy_process_rasterization_rate_map_t proxy_map, __unsafe_unretained MTLRasterizationRateMapDescriptor* descriptors[2]), (proxy_map, descriptors))

#define cp_proxy_process_rasterization_rate_map_get_metal_descriptors softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_descriptors
#define cp_proxy_process_rasterization_rate_map_get_metal_descriptors softLink_CompositorServices_cp_proxy_process_rasterization_rate_map_get_metal_descriptors
#define cp_rasterization_rate_map_update_from_descriptor softLink_CompositorServices_cp_rasterization_rate_map_update_from_descriptor
#define cp_drawable_get_layer_renderer_layout softLink_CompositorServices_cp_drawable_get_layer_renderer_layout

#endif

WTF_WEAK_LINK_FORCE_IMPORT(EGL_Initialize);

namespace WebCore {

bool platformIsANGLEAvailable()
{
    // MAVERICKS_BACKPORT: ANGLE is STATICALLY linked into WebCore (not a separately-loaded dylib), so
    // the weak-link "is the ANGLE dylib present" check (EGL_Initialize != NULL) is both unnecessary
    // and unsafe here (reading the weak-imported symbol's address crashes under static linking).
    // ANGLE is always present in this build.
    return true;
}

void* createPbufferAndAttachIOSurface(GCGLDisplay display, GCGLConfig config, GCGLenum target, GCGLint usageHint, GCGLenum internalFormat, GCGLsizei width, GCGLsizei height, GCGLenum type, IOSurfaceRef surface, GCGLuint plane)
{
    auto eglTextureTarget = target == GL_TEXTURE_RECTANGLE_ANGLE ? EGL_TEXTURE_RECTANGLE_ANGLE : EGL_TEXTURE_2D;

    const EGLint surfaceAttributes[] = {
        EGL_WIDTH, width,
        EGL_HEIGHT, height,
        EGL_IOSURFACE_PLANE_ANGLE, static_cast<EGLint>(plane),
        EGL_TEXTURE_TARGET, static_cast<EGLint>(eglTextureTarget),
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, static_cast<EGLint>(internalFormat),
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, static_cast<EGLint>(type),
        // Only has an effect on the iOS Simulator.
        EGL_IOSURFACE_USAGE_HINT_ANGLE, usageHint,
        EGL_NONE, EGL_NONE
    };

    EGLSurface pbuffer = EGL_CreatePbufferFromClientBuffer(display, EGL_IOSURFACE_ANGLE, surface, config, surfaceAttributes);
    if (!pbuffer)
        return nullptr;

    if (!EGL_BindTexImage(display, pbuffer, EGL_BACK_BUFFER)) {
        EGL_DestroySurface(display, pbuffer);
        return nullptr;
    }

    return pbuffer;
}

void destroyPbufferAndDetachIOSurface(EGLDisplay display, void* handle)
{
    EGL_ReleaseTexImage(display, handle, EGL_BACK_BUFFER);
    EGL_DestroySurface(display, handle);
}

#if !WK_ANGLE_METAL
// MAVERICKS_BACKPORT: Metal-only helpers are stubbed (callers compiled out with the OpenGL/CGL backend).
RetainPtr<id<MTLRasterizationRateMap>> newRasterizationRateMap(GCGLDisplay, IntSize, IntSize, IntSize, std::span<const float>, std::span<const float>, std::span<const float>)
{
    return nullptr;
}

RetainPtr<id<MTLSharedEvent>> newSharedEventWithMachPort(GCGLDisplay, mach_port_t)
{
    return nullptr;
}

RetainPtr<id<MTLSharedEvent>> newSharedEvent(GCGLDisplay)
{
    return nullptr;
}
#else
RetainPtr<id<MTLRasterizationRateMap>> newRasterizationRateMap(GCGLDisplay display, IntSize physicalSizeLeft, IntSize physicalSizeRight, IntSize screenSize, std::span<const float> horizontalSamplesLeft, std::span<const float> verticalSamples, std::span<const float> horizontalSamplesRight)
{
    EGLDeviceEXT device = EGL_NO_DEVICE_EXT;
    if (!EGL_QueryDisplayAttribEXT(display, EGL_DEVICE_EXT, reinterpret_cast<EGLAttrib*>(&device)))
        return nullptr;

    id<MTLDevice> mtlDevice = nil;
    if (!EGL_QueryDeviceAttribEXT(device, EGL_METAL_DEVICE_ANGLE, reinterpret_cast<EGLAttrib*>(&mtlDevice)))
        return nullptr;

    UNUSED_PARAM(physicalSizeLeft);
    UNUSED_PARAM(physicalSizeRight);

#if USE(APPLE_INTERNAL_SDK) && PLATFORM(VISION)
    RetainPtr<MTLRasterizationRateMapDescriptor> descriptor = adoptNS([MTLRasterizationRateMapDescriptor new]);
    id<MTLRasterizationRateMapDescriptorSPI> descriptor_spi = (id<MTLRasterizationRateMapDescriptorSPI>)descriptor.get();
        descriptor_spi.skipSampleValidationAndApplySampleAtTileGranularity = YES;
    descriptor_spi.mutability = MTLMutabilityMutable;
    descriptor_spi.minFactor  = 0.01;

    constexpr MTLSize maxSampleCount { 256, 256, 1 };
    RetainPtr<MTLRasterizationRateLayerDescriptor> layerDescriptorLeft = adoptNS([[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:maxSampleCount]);
    RetainPtr<MTLRasterizationRateLayerDescriptor> layerDescriptorRight = adoptNS([[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:maxSampleCount]);

    if (horizontalSamplesLeft.size() > maxSampleCount.width || horizontalSamplesRight.size() > maxSampleCount.width || verticalSamples.size() > maxSampleCount.height || !layerDescriptorLeft.get() || !layerDescriptorRight.get())
        return nullptr;

    memcpySpan(unsafeMakeSpan([layerDescriptorLeft horizontalSampleStorage], [layerDescriptorLeft sampleCount].width), horizontalSamplesLeft);
    memcpySpan(unsafeMakeSpan([layerDescriptorLeft verticalSampleStorage], [layerDescriptorLeft sampleCount].height), verticalSamples);
    [layerDescriptorLeft setSampleCount:MTLSizeMake(horizontalSamplesLeft.size(), verticalSamples.size(), 0)];

    memcpySpan(unsafeMakeSpan([layerDescriptorRight horizontalSampleStorage], [layerDescriptorRight sampleCount].width), horizontalSamplesRight);
    memcpySpan(unsafeMakeSpan([layerDescriptorRight verticalSampleStorage], [layerDescriptorRight sampleCount].height), verticalSamples);
    [layerDescriptorRight setSampleCount:MTLSizeMake(horizontalSamplesRight.size(), verticalSamples.size(), 0)];

    [descriptor setScreenSize:MTLSizeMake(screenSize.width(), screenSize.height(), 0)];
    [descriptor layers][0] = layerDescriptorLeft.get();
    [descriptor layers][1] = layerDescriptorRight.get();

    auto rateMap = cp_proxy_process_rasterization_rate_map_create(mtlDevice, cp_layer_renderer_layout_shared, 2);
    cp_rasterization_rate_map_update_shared_from_layered_descriptor(rateMap, descriptor.get());

    RetainPtr<id<MTLRasterizationRateMap>> rasterizationRateMap = cp_proxy_process_rasterization_rate_map_get_metal_maps(rateMap).firstObject;
#else
    RetainPtr<id<MTLRasterizationRateMap>> rasterizationRateMap;
    UNUSED_PARAM(display);
    UNUSED_PARAM(physicalSizeLeft);
    UNUSED_PARAM(physicalSizeRight);
    UNUSED_PARAM(screenSize);
    UNUSED_PARAM(horizontalSamplesLeft);
    UNUSED_PARAM(verticalSamples);
    UNUSED_PARAM(horizontalSamplesRight);
#endif
    return rasterizationRateMap;
}

RetainPtr<id<MTLSharedEvent>> newSharedEventWithMachPort(GCGLDisplay display, mach_port_t machPort)
{
    // FIXME: Check for invalid mach_port_t
    EGLDeviceEXT device = EGL_NO_DEVICE_EXT;
    if (!EGL_QueryDisplayAttribEXT(display, EGL_DEVICE_EXT, reinterpret_cast<EGLAttrib*>(&device)))
        return nullptr;

    id<MTLDevice> mtlDevice = nil;
    if (!EGL_QueryDeviceAttribEXT(device, EGL_METAL_DEVICE_ANGLE, reinterpret_cast<EGLAttrib*>(&mtlDevice)))
        return nullptr;

    return adoptNS([(id<MTLDeviceSPI>)mtlDevice newSharedEventWithMachPort:machPort]);
}

RetainPtr<id<MTLSharedEvent>> newSharedEvent(GCGLDisplay display)
{
    EGLDeviceEXT device = EGL_NO_DEVICE_EXT;
    if (!EGL_QueryDisplayAttribEXT(display, EGL_DEVICE_EXT, reinterpret_cast<EGLAttrib*>(&device)))
        return nullptr;

    id<MTLDevice> mtlDevice = nil;
    if (!EGL_QueryDeviceAttribEXT(device, EGL_METAL_DEVICE_ANGLE, reinterpret_cast<EGLAttrib*>(&mtlDevice)))
        return nullptr;

    return adoptNS([mtlDevice newSharedEvent]);
}
// MAVERICKS_BACKPORT: closes the WK_ANGLE_METAL split selecting Metal vs. the no-op stubs (Metal is 10.11+).
#endif // WK_ANGLE_METAL

}

#endif
