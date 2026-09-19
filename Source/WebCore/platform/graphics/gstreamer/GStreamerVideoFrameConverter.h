/*
 *  Copyright (C) 2025 Igalia, S.L
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER)

#include "GRefPtrGStreamer.h"
#include <wtf/Forward.h>
#include <wtf/Lock.h> // MAVERICKS_BACKPORT: shared conversion and output-pool lookup serialization.
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>

// MAVERICKS_BACKPORT: the Cocoa converter owns its IOSurface output pools.
#if PLATFORM(COCOA)
#include "IntSize.h"
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RetainPtr.h>
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;
typedef struct __CVPixelBufferPool* CVPixelBufferPoolRef;
#endif

namespace WebCore {

#if PLATFORM(COCOA)
struct PlatformVideoColorSpace;
#endif // MAVERICKS_BACKPORT: Cocoa pixel-buffer colour metadata.


class GStreamerVideoFrameConverter final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<GStreamerVideoFrameConverter> {
    WTF_MAKE_TZONE_ALLOCATED(GStreamerVideoFrameConverter);
    friend NeverDestroyed<GStreamerVideoFrameConverter>;

public:
    static GStreamerVideoFrameConverter& singleton();

    // Do nothing since this is a singleton object.
    void ref() const { }
    void deref() const { }

    [[nodiscard]] GRefPtr<GstSample> convert(const GRefPtr<GstSample>&, const GRefPtr<GstCaps>&);

#if PLATFORM(COCOA)
    // MAVERICKS_BACKPORT: packed RGB and planar YUV samples back Cocoa rendering and IPC.
    RetainPtr<CVPixelBufferRef> pixelBufferFromSample(const GRefPtr<GstSample>&, PlatformVideoColorSpace);
#endif

private:
    GStreamerVideoFrameConverter();
    Lock m_lock; // MAVERICKS_BACKPORT: conversion pipelines are shared by streaming and canvas callers.

    class Pipeline {
        WTF_MAKE_TZONE_ALLOCATED(Pipeline);
    public:
        enum class Type : uint8_t {
            SystemMemory,
#if USE(GSTREAMER_GL)
            GLMemory,
            DMABufMemory
#endif
        };
        Pipeline(Type);
        ~Pipeline();

        GRefPtr<GstSample> run(const GRefPtr<GstSample>&, GstCaps*);

    private:
        Type m_type { Type::SystemMemory };
        GRefPtr<GstElement> m_pipeline;
        GRefPtr<GstElement> m_src;
        GRefPtr<GstElement> m_sink;
        GRefPtr<GstElement> m_capsfilter;
    };

    Pipeline& ensurePipeline(GstCaps*);
    void releaseUnusedSystemMemoryPipelineTimerFired();
#if USE(GSTREAMER_GL)
    void releaseUnusedGLMemoryPipelineTimerFired();
    void releaseUnusedDMABufMemoryPipelineTimerFired();
#endif

#if PLATFORM(COCOA)
    // MAVERICKS_BACKPORT: frames reuse an IOSurface pool per size and pixel format; a pool unused for the
    // pipeline release interval is dropped on the next lookup.
    struct CVPixelBufferPoolEntry {
        RetainPtr<CVPixelBufferPoolRef> pool;
        MonotonicTime lastUse;
    };
    Lock m_cvPixelBufferPoolLock;
    HashMap<std::pair<uint64_t, uint32_t>, CVPixelBufferPoolEntry> m_cvPixelBufferPools WTF_GUARDED_BY_LOCK(m_cvPixelBufferPoolLock);
#endif
    std::unique_ptr<Pipeline> m_systemMemoryPipeline;
    std::unique_ptr<RunLoop::Timer> m_releaseUnusedSystemMemoryPipelineTimer;
#if USE(GSTREAMER_GL)
    std::unique_ptr<Pipeline> m_glMemoryPipeline;
    std::unique_ptr<RunLoop::Timer> m_releaseUnusedGLMemoryPipelineTimer;
    std::unique_ptr<Pipeline> m_dmabufMemoryPipeline;
    std::unique_ptr<RunLoop::Timer> m_releaseUnusedDMABufMemoryPipelineTimer;
#endif
};

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER)
