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
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>

// AQUAWEBKIT: the Cocoa converter owns its IOSurface output pools.
#if PLATFORM(COCOA)
#include "IntSize.h"
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RetainPtr.h>
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;
typedef struct __CVPixelBufferPool* CVPixelBufferPoolRef;
#endif

namespace WebCore {

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
    // AQUAWEBKIT: IOSurface buffers for Cocoa rendering and IPC, from one pool per size and pixel format.
    RetainPtr<CVPixelBufferRef> pooledPixelBuffer(IntSize, OSType);
#endif

private:
    GStreamerVideoFrameConverter();
    Lock m_lock; // AQUAWEBKIT: conversion pipelines are shared by streaming and canvas callers.

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
    // AQUAWEBKIT: a resource's last use, and whether its release timer is armed. A use arms the timer only
    // when it is not; the timer releases the resource once it has been unused for the whole interval.
    struct ReleaseSchedule {
        MonotonicTime lastUse;
        bool armed { false };
        bool noteUse()
        {
            lastUse = MonotonicTime::now();
            return !std::exchange(armed, true);
        }
        std::optional<Seconds> remainingBeforeRelease(Seconds interval)
        {
            auto idle = MonotonicTime::now() - lastUse;
            if (idle < interval)
                return interval - idle;
            armed = false;
            return std::nullopt;
        }
    };
    ReleaseSchedule m_systemMemoryPipelineRelease WTF_GUARDED_BY_LOCK(m_lock); // AQUAWEBKIT: see ReleaseSchedule.
    void releaseUnusedSystemMemoryPipelineTimerFired();
#if USE(GSTREAMER_GL)
    void releaseUnusedGLMemoryPipelineTimerFired();
    void releaseUnusedDMABufMemoryPipelineTimerFired();
    ReleaseSchedule m_glMemoryPipelineRelease WTF_GUARDED_BY_LOCK(m_lock); // AQUAWEBKIT: see ReleaseSchedule.
    ReleaseSchedule m_dmabufMemoryPipelineRelease WTF_GUARDED_BY_LOCK(m_lock); // AQUAWEBKIT: see ReleaseSchedule.
#endif

#if PLATFORM(COCOA)
    // AQUAWEBKIT: the pools are released once none has served a buffer for the pipeline release interval.
    void releaseUnusedPixelBufferPoolsTimerFired();
    Lock m_cvPixelBufferPoolLock;
    HashMap<std::pair<uint64_t, uint32_t>, RetainPtr<CVPixelBufferPoolRef>> m_cvPixelBufferPools WTF_GUARDED_BY_LOCK(m_cvPixelBufferPoolLock);
    ReleaseSchedule m_cvPixelBufferPoolsRelease WTF_GUARDED_BY_LOCK(m_cvPixelBufferPoolLock);
    std::unique_ptr<RunLoop::Timer> m_releaseUnusedPixelBufferPoolsTimer WTF_GUARDED_BY_LOCK(m_cvPixelBufferPoolLock);
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
