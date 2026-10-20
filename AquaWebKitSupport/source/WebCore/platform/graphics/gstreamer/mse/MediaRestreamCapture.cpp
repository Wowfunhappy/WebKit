#include "config.h"
#include "MediaRestreamCapture.h"
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/audio/audio.h>
#include <gst/audio/gstaudiobasesink.h>
#include <wtf/text/StringBuilder.h>
#include <gst/video/video.h>
#include <wtf/MainThread.h>
#include <wtf/WorkQueue.h>
#include <wtf/glib/GUniquePtr.h>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <limits>
#include <mutex>

namespace WebCore {
namespace {
// Frame-threaded encoding retains several full-resolution raw frames.
constexpr uint64_t inputBudget = 256 * 1024 * 1024;
// Encoded queues allow one-second fragments plus the 240 Mbit VBV burst.
constexpr uint64_t outputBudget = 128 * 1024 * 1024;

struct Budget {
    std::atomic<uint64_t> bytes { 0 };
    bool acquire(uint64_t size, uint64_t limit)
    {
        auto used = bytes.fetch_add(size);
        if (size <= limit && used <= limit - size)
            return true;
        bytes.fetch_sub(size);
        return false;
    }
};

bool accountBuffer(GstBuffer* buffer, const std::shared_ptr<Budget>& budget, uint64_t limit)
{
    struct Allocation { std::shared_ptr<Budget> budget; uint64_t bytes; };
    auto payload = gst_buffer_get_size(buffer);
    constexpr auto overhead = sizeof(GstBuffer) + sizeof(GstMemory) + sizeof(Allocation);
    if (!payload || payload > limit - overhead || !budget->acquire(payload + overhead, limit))
        return false;
    auto size = payload + overhead;
    gst_mini_object_weak_ref(GST_MINI_OBJECT(buffer), [](gpointer data, GstMiniObject*) {
        auto allocation = std::unique_ptr<Allocation>(static_cast<Allocation*>(data));
        allocation->budget->bytes.fetch_sub(allocation->bytes);
    }, new Allocation { budget, size });
    return true;
}

GRefPtr<GstElement> findPlaySink(GstElement* pipeline)
{
    GUniquePtr<GstIterator> iterator(gst_bin_iterate_recurse(GST_BIN(pipeline)));
    GValue value = G_VALUE_INIT;
    GRefPtr<GstElement> result;
    for (;;) {
        auto next = gst_iterator_next(iterator.get(), &value);
        if (next == GST_ITERATOR_RESYNC) {
            gst_iterator_resync(iterator.get());
            continue;
        }
        if (next != GST_ITERATOR_OK)
            break;
        auto* element = GST_ELEMENT(g_value_get_object(&value));
        auto* factory = gst_element_get_factory(element);
        if (factory && !strcmp(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)), "playsink"))
            result = element;
        g_value_unset(&value);
        if (result)
            break;
    }
    return result;
}
}

struct MediaRestreamCapture::Impl : std::enable_shared_from_this<Impl> {
    struct Track {
        GRefPtr<GstPad> pad;
        GRefPtr<GstElement> source;
        GRefPtr<GstCaps> caps;
        GRefPtr<GstCaps> captureCaps;
        GstSegment segment;
        gulong probe { 0 };
        bool video { false };
        bool initialized { false };
        bool segmentReady { false };
        bool flushing { false };
        bool ended { false };
        GstClockTime last { GST_CLOCK_TIME_NONE };
        GstClockTime first { GST_CLOCK_TIME_NONE };
        struct Gap { GstClockTime timestamp; GstClockTime duration; GstGapFlags flags; guint32 sequence; };
        struct Pending { GRefPtr<GstBuffer> buffer; GRefPtr<GstCaps> caps; std::optional<Gap> gap; };
        Vector<Pending> pending;
        bool eosSent { false };
        bool pushedBuffer { false };
        GstClockTime videoStart { GST_CLOCK_TIME_NONE };
        GRefPtr<GstBuffer> lastVideoFrame;
        GRefPtr<GstCaps> lastVideoCaps;
    };
    Vector<std::unique_ptr<Track>> tracks;
    GRefPtr<GstElement> playbackPipeline;
    gulong sinkRemoved { 0 };
    uint64_t audioPackets { 0 };
    GstAudioInfo audioFormat { };
    uint64_t videoFrameScale { GST_SECOND };
    uint32_t videoFrameRate { 30 };
    std::atomic<GstClockTime> encodedEnd { 0 };
    GRefPtr<GstElement> pipeline;
    GRefPtr<GstElement> playbackSink;
    gulong padAdded { 0 };
    gulong padRemoved { 0 };
    GRefPtr<GstBus> bus;
    Callbacks callbacks;
    std::shared_ptr<MediaRestreamFrameQueue> frames;
    uint64_t frameGeneration { 0 };
    std::atomic<bool> stopped { false };
    std::atomic<bool> interrupted { false };
    std::atomic<bool> failed { false };
    std::shared_ptr<Budget> rawBudget { std::make_shared<Budget>() };
    std::shared_ptr<Budget> normalizedBudget { std::make_shared<Budget>() };
    std::mutex eventLock;
    bool restartPosted { false };
    std::atomic<bool> inputCompleted { false };
    GstClockTime captureStart { GST_CLOCK_TIME_NONE };
    unsigned pendingEvents { 0 };
    std::shared_ptr<Budget> encodedBudget { std::make_shared<Budget>() };
    std::shared_ptr<Budget> deliveryBudget { std::make_shared<Budget>() };
    std::mutex deliveryLock;
    std::condition_variable deliveryAvailable;
    std::mutex outputLock;
    SharedBufferBuilder output;
    uint64_t outputBytes { 0 };
    GstClockTime opened { GST_CLOCK_TIME_NONE };
    struct Fragment { GstClockTime start; Ref<SharedBuffer> data; };
    std::optional<Fragment> pending;

    void fail()
    {
        if (failed.exchange(true) || stopped)
            return;
        {
            std::lock_guard lock(deliveryLock);
            deliveryAvailable.notify_all();
        }
        callOnMainThread([self = shared_from_this()] {
            if (!self->stopped)
                self->callbacks.failed();
        });
    }

    void continueAfterEnd()
    {
        if (!inputCompleted || interrupted.exchange(true) || stopped)
            return;
        callOnMainThread([self = shared_from_this()] {
            if (!self->stopped)
                self->callbacks.interrupted();
        });
    }

    void streamEvent(Track& track, GstEvent* event)
    {
        std::lock_guard lock(eventLock);
        if (inputCompleted) {
            if (GST_EVENT_TYPE(event) == GST_EVENT_STREAM_START)
                continueAfterEnd();
            return;
        }
        if (GST_EVENT_TYPE(event) == GST_EVENT_STREAM_START) {
            // A selected track starts a new stream before its segment arrives.
            if (track.initialized && !interrupted.exchange(true)) {
                for (auto& selected : tracks)
                    selected->segmentReady = !selected->flushing;
            }
            track.ended = false;
            track.segmentReady = false;
        } else if (GST_EVENT_TYPE(event) == GST_EVENT_CAPS) {
            GstCaps* caps;
            gst_event_parse_caps(event, &caps);
            track.caps = caps;
            if (!track.video) {
                GstAudioInfo format;
                gst_audio_info_init(&format);
                if (!gst_audio_info_from_caps(&format, caps))
                    return fail();
                if ((format.channels != audioFormat.channels || !std::equal(format.position, format.position + format.channels, audioFormat.position)) && !interrupted.exchange(true)) {
                    for (auto& selected : tracks)
                        selected->segmentReady = !selected->flushing;
                }
            }
        } else if (GST_EVENT_TYPE(event) == GST_EVENT_FLUSH_START) {
            if (!interrupted.exchange(true)) {
                for (auto& selected : tracks)
                    selected->segmentReady = false;
            }
            track.flushing = true;
            track.ended = false;
            track.segmentReady = false;
        } else if (GST_EVENT_TYPE(event) == GST_EVENT_FLUSH_STOP)
            track.flushing = false;
        else if (GST_EVENT_TYPE(event) == GST_EVENT_SEGMENT) {
            GstSegment segment;
            gst_event_copy_segment(event, &segment);
            if (track.initialized && !interrupted && (segment.start != track.segment.start || segment.time != track.segment.time || segment.base != track.segment.base || segment.offset != track.segment.offset || segment.rate != track.segment.rate || segment.applied_rate != track.segment.applied_rate)) {
                interrupted = true;
                for (auto& selected : tracks)
                    selected->segmentReady = !selected->flushing;
            }
            track.ended = false;
            track.segment = segment;
            track.segmentReady = !track.flushing;
        }
        if (GST_EVENT_TYPE(event) == GST_EVENT_EOS) {
            if (!interrupted && !bootstrap(track))
                return fail();
            track.ended = true;
            if (std::all_of(tracks.begin(), tracks.end(), [](auto& selected) { return selected->ended; }))
                inputCompleted = true;
            if (!interrupted)
                startAlignedInput();
        }
        if (interrupted && !restartPosted && std::all_of(tracks.begin(), tracks.end(), [](auto& track) { return track->ended || (track->segmentReady && !track->flushing); })) {
            restartPosted = true;
            callOnMainThread([self = shared_from_this()] {
                {
                    std::lock_guard lock(self->eventLock);
                    if (self->stopped)
                        return;
                    if (!std::all_of(self->tracks.begin(), self->tracks.end(), [](auto& track) { return track->ended || (track->segmentReady && !track->flushing); })) {
                        self->restartPosted = false;
                        return;
                    }
                }
                self->callbacks.interrupted();
            });
        }
    }

    void deliver(Fragment&& fragment, GstClockTime end)
    {
        if (end <= fragment.start || !GST_CLOCK_TIME_IS_VALID(end))
            return fail();
        auto size = fragment.data->size();
        double sourceRate, sourceOffset;
        {
            std::lock_guard lock(eventLock);
            auto& segment = tracks.first()->segment;
            if (segment.offset >= GST_CLOCK_TIME_NONE - segment.start)
                return fail();
            auto anchor = segment.start + segment.offset;
            auto media = gst_segment_to_stream_time(&segment, GST_FORMAT_TIME, anchor);
            auto running = gst_segment_to_running_time(&segment, GST_FORMAT_TIME, anchor);
            if (!GST_CLOCK_TIME_IS_VALID(media) || !GST_CLOCK_TIME_IS_VALID(running))
                return fail();
            sourceRate = segment.rate * segment.applied_rate;
            sourceOffset = static_cast<double>(media) / GST_SECOND - static_cast<double>(running) / GST_SECOND * sourceRate;
        }
        if (!std::isfinite(sourceRate) || sourceRate <= 0 || !std::isfinite(sourceOffset) || size > outputBudget)
            return fail();
        {
            std::unique_lock lock(deliveryLock);
            deliveryAvailable.wait(lock, [&] {
                return stopped || failed || interrupted || deliveryBudget->bytes.load() <= outputBudget - size;
            });
            if (stopped || failed || interrupted)
                return;
            deliveryBudget->bytes.fetch_add(size);
        }
        callOnMainThread([self = shared_from_this(), fragment = WTF::move(fragment), end, size, sourceRate, sourceOffset]() mutable {
            CompletionHandler<void()> completion = [self, size] {
                {
                    std::lock_guard lock(self->deliveryLock);
                    self->deliveryBudget->bytes.fetch_sub(size);
                }
                self->deliveryAvailable.notify_all();
            };
            if (!self->stopped && !self->failed && !self->interrupted)
                self->callbacks.fragment(static_cast<double>(fragment.start) / GST_SECOND, static_cast<double>(end) / GST_SECOND, sourceRate, sourceOffset, WTF::move(fragment.data), WTF::move(completion));
            else
                completion();
        });
    }

    void message(GstMessage* message)
    {
        if (stopped || failed || interrupted)
            return;
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
            GUniqueOutPtr<GError> error;
            GUniqueOutPtr<char> debug;
            gst_message_parse_error(message, &error.outPtr(), &debug.outPtr());
            g_warning("Media restream: %s (%s)", error ? error->message : "encoder failure", debug ? debug.get() : "");
            return fail();
        }
        std::lock_guard lock(outputLock);
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) {
            if (pending) {
                auto fragment = std::exchange(pending, std::nullopt);
                auto end = encodedEnd.load();
                deliver(WTF::move(*fragment), end);
            }
            callOnMainThread([self = shared_from_this()] {
                if (!self->stopped && !self->failed && !self->interrupted)
                    self->callbacks.ended();
            });
            return;
        }
        if (GST_MESSAGE_TYPE(message) != GST_MESSAGE_ELEMENT)
            return;
        auto* structure = gst_message_get_structure(message);
        if (gst_structure_has_name(structure, "splitmuxsink-fragment-opened")) {
            if (!gst_structure_get_uint64(structure, "running-time", &opened))
                return fail();
            if (pending) {
                auto fragment = std::exchange(pending, std::nullopt);
                deliver(WTF::move(*fragment), opened);
            }
        } else if (gst_structure_has_name(structure, "splitmuxsink-fragment-closed")) {
            // A completed input can close a fragment without muxed packets.
            if (inputCompleted && !outputBytes)
                return;
            guint64 duration = 0;
            if (!gst_structure_get_uint64(structure, "fragment-duration", &duration) || !GST_CLOCK_TIME_IS_VALID(opened)
                || !duration || !GST_CLOCK_TIME_IS_VALID(duration) || !outputBytes || pending)
                return fail();
            pending.emplace(Fragment { opened, output.takeBufferAsContiguous() });
            outputBytes = 0;
        }
    }

    bool bootstrap(Track& track)
    {
        if (!track.caps)
            track.caps = adoptGRef(gst_pad_get_current_caps(track.pad.get()));
        if (!track.segmentReady) {
            GRefPtr event = adoptGRef(gst_pad_get_sticky_event(track.pad.get(), GST_EVENT_SEGMENT, 0));
            if (!event)
                return false;
            gst_event_copy_segment(event.get(), &track.segment);
            track.segmentReady = true;
        }
        if (!track.caps || !gst_caps_is_fixed(track.caps.get()) || gst_caps_is_empty(track.caps.get()))
            return false;
        auto* features = gst_caps_get_features(track.caps.get(), 0);
        auto* structure = gst_caps_get_structure(track.caps.get(), 0);
        if (track.segment.format != GST_FORMAT_TIME || !std::isfinite(track.segment.rate) || track.segment.rate <= 0 || !std::isfinite(track.segment.applied_rate) || track.segment.applied_rate <= 0
            || !gst_caps_features_contains(features, GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY)
            || !gst_structure_has_name(structure, track.video ? "video/x-raw" : "audio/x-raw"))
            return false;
        track.captureCaps = track.caps;
        if (!track.video && track.segment.rate != 1) {
            int rate;
            if (!gst_structure_get_int(structure, "rate", &rate))
                return false;
            auto renderedRate = rate * track.segment.rate;
            if (!std::isfinite(renderedRate) || renderedRate < 1 || renderedRate > std::numeric_limits<int>::max() || renderedRate != std::floor(renderedRate))
                return false;
            track.captureCaps = adoptGRef(gst_caps_copy(track.caps.get()));
            gst_structure_set(gst_caps_get_structure(track.captureCaps.get(), 0), "rate", G_TYPE_INT, static_cast<int>(renderedRate), nullptr);
        }
        gst_app_src_set_caps(GST_APP_SRC(track.source.get()), track.captureCaps.get());
        track.initialized = true;
        return true;
    }

    void push(Track& track, GRefPtr<GstBuffer>&& buffer, GstCaps* caps)
    {
        if (GST_BUFFER_PTS(buffer.get()) < captureStart) {
            if (track.video)
                return;
            GstAudioInfo info;
            gst_audio_info_init(&info);
            if (!gst_audio_info_from_caps(&info, caps))
                return fail();
            GstSegment segment;
            gst_segment_init(&segment, GST_FORMAT_TIME);
            segment.start = captureStart;
            auto* original = buffer.get();
            buffer = adoptGRef(gst_audio_buffer_clip(buffer.leakRef(), &segment, GST_AUDIO_INFO_RATE(&info), GST_AUDIO_INFO_BPF(&info)));
            if (!buffer)
                return;
            if (buffer.get() != original && !accountBuffer(buffer.get(), rawBudget, inputBudget))
                return fail();
        }
        if (track.video) {
            if (!track.pushedBuffer)
                track.videoStart = GST_BUFFER_PTS(buffer.get());
            track.lastVideoFrame = buffer;
            track.lastVideoCaps = caps;
        }
        track.pushedBuffer = true;
        gst_app_src_set_caps(GST_APP_SRC(track.source.get()), caps);
        if (gst_app_src_push_buffer(GST_APP_SRC(track.source.get()), buffer.leakRef()) != GST_FLOW_OK)
            fail();
    }

    void pushGap(Track& track, GRefPtr<GstEvent>&& event, GstCaps* caps)
    {
        GstClockTime timestamp, duration;
        gst_event_parse_gap(event.get(), &timestamp, &duration);
        if (timestamp < captureStart) {
            auto trim = captureStart - timestamp;
            if (GST_CLOCK_TIME_IS_VALID(duration)) {
                if (duration <= trim)
                    return;
                duration -= trim;
            }
            timestamp = captureStart;
            gst_structure_set(gst_event_writable_structure(event.get()), "timestamp", G_TYPE_UINT64, timestamp, "duration", G_TYPE_UINT64, duration, nullptr);
        }
        if (track.video && track.lastVideoFrame && GST_CLOCK_TIME_IS_VALID(duration) && duration) {
            if (duration >= GST_CLOCK_TIME_NONE - timestamp)
                return fail();
            auto end = timestamp + duration;
            if (!GST_CLOCK_TIME_IS_VALID(track.videoStart) || end <= track.videoStart)
                return;
            auto frame = gst_util_uint64_scale(end - track.videoStart - 1, videoFrameRate, videoFrameScale);
            auto time = std::max(timestamp, track.videoStart + gst_util_uint64_scale(frame, videoFrameScale, videoFrameRate));
            if (time <= GST_BUFFER_PTS(track.lastVideoFrame.get()))
                return;
            GRefPtr held = adoptGRef(gst_buffer_copy(track.lastVideoFrame.get()));
            if (!held || !accountBuffer(held.get(), rawBudget, inputBudget))
                return fail();
            GST_BUFFER_PTS(held.get()) = time;
            GST_BUFFER_DURATION(held.get()) = end - time;
            GST_BUFFER_FLAG_UNSET(held.get(), GST_BUFFER_FLAG_DISCONT);
            return push(track, WTF::move(held), track.lastVideoCaps.get());
        }
        if (!track.video && !track.pushedBuffer) {
            GstAudioInfo audio;
            gst_audio_info_init(&audio);
            if (!GST_CLOCK_TIME_IS_VALID(duration))
                return;
            if (!gst_audio_info_from_caps(&audio, caps))
                return fail();
            auto frames = gst_util_uint64_scale_ceil(duration, GST_AUDIO_INFO_RATE(&audio), GST_SECOND);
            if (!frames)
                return;
            if (frames > inputBudget / GST_AUDIO_INFO_BPF(&audio))
                return fail();
            GRefPtr silence = adoptGRef(gst_buffer_new_allocate(nullptr, frames * GST_AUDIO_INFO_BPF(&audio), nullptr));
            if (!silence || !accountBuffer(silence.get(), rawBudget, inputBudget))
                return fail();
            {
                GstMappedBuffer mapped(silence.get(), GST_MAP_WRITE);
                if (!mapped)
                    return fail();
                gst_audio_format_info_fill_silence(audio.finfo, mapped.data(), mapped.size());
            }
            if (!gst_buffer_add_audio_meta(silence.get(), &audio, frames, nullptr))
                return fail();
            GST_BUFFER_PTS(silence.get()) = timestamp;
            GST_BUFFER_DURATION(silence.get()) = duration;
            GST_BUFFER_FLAG_SET(silence.get(), GST_BUFFER_FLAG_GAP);
            return push(track, WTF::move(silence), caps);
        }
        gst_app_src_set_caps(GST_APP_SRC(track.source.get()), caps);
        if (!gst_element_send_event(track.source.get(), event.leakRef()))
            fail();
    }

    void startAlignedInput()
    {
        if (!GST_CLOCK_TIME_IS_VALID(captureStart)) {
            if (!std::all_of(tracks.begin(), tracks.end(), [](auto& track) { return GST_CLOCK_TIME_IS_VALID(track->first) || track->ended; }))
                return;
            captureStart = 0;
            for (auto& track : tracks) {
                if (GST_CLOCK_TIME_IS_VALID(track->first))
                    captureStart = std::max(captureStart, track->first);
            }
        }
        for (auto& track : tracks) {
            auto pending = std::exchange(track->pending, { });
            for (auto& sample : pending) {
                if (sample.gap) {
                    --pendingEvents;
                    GRefPtr event = adoptGRef(gst_event_new_gap(sample.gap->timestamp, sample.gap->duration));
                    gst_event_set_gap_flags(event.get(), sample.gap->flags);
                    gst_event_set_seqnum(event.get(), sample.gap->sequence);
                    pushGap(*track, WTF::move(event), sample.caps.get());
                } else
                    push(*track, WTF::move(sample.buffer), sample.caps.get());
            }
            if (track->ended && !std::exchange(track->eosSent, true)) {
                if (!frames && track->video && track->lastVideoFrame && GST_BUFFER_DURATION_IS_VALID(track->lastVideoFrame.get())) {
                    GRefPtr gap = adoptGRef(gst_event_new_gap(GST_BUFFER_PTS(track->lastVideoFrame.get()), GST_BUFFER_DURATION(track->lastVideoFrame.get())));
                    pushGap(*track, WTF::move(gap), track->lastVideoCaps.get());
                }
                gst_app_src_end_of_stream(GST_APP_SRC(track->source.get()));
            }
        }
    }

    void gap(Track& track, GstEvent* event)
    {
        if (inputCompleted || interrupted || !bootstrap(track)) {
            if (!inputCompleted && !interrupted) fail();
            return;
        }
        GstClockTime timestamp, duration;
        gst_event_parse_gap(event, &timestamp, &duration);
        if (!duration || (!GST_CLOCK_TIME_IS_VALID(duration) && !GST_CLOCK_TIME_IS_VALID(track.first)))
            return;
        auto time = gst_segment_to_running_time(&track.segment, GST_FORMAT_TIME, timestamp);
        if (GST_CLOCK_TIME_IS_VALID(time)) {
            if (GST_CLOCK_TIME_IS_VALID(duration)) {
                auto renderedDuration = static_cast<long double>(duration) / track.segment.rate;
                if (renderedDuration >= GST_CLOCK_TIME_NONE) {
                    fail();
                    return;
                }
                duration = renderedDuration;
            }
            if (!GST_CLOCK_TIME_IS_VALID(track.first))
                track.first = time;
            if (!GST_CLOCK_TIME_IS_VALID(captureStart)) {
                if (pendingEvents >= inputBudget / sizeof(Track::Pending)) {
                    fail();
                    return;
                }
                GstGapFlags flags = static_cast<GstGapFlags>(0);
                gst_event_parse_gap_flags(event, &flags);
                ++pendingEvents;
                track.pending.append({ nullptr, track.captureCaps, Track::Gap { time, duration, flags, gst_event_get_seqnum(event) } });
                startAlignedInput();
            } else {
                GRefPtr gap = adoptGRef(gst_event_copy(event));
                gst_structure_set(gst_event_writable_structure(gap.get()), "timestamp", G_TYPE_UINT64, time, "duration", G_TYPE_UINT64, duration, nullptr);
                pushGap(track, WTF::move(gap), track.captureCaps.get());
            }
        }
    }

    void sample(Track& track, GstBuffer* original)
    {
        std::lock_guard lock(eventLock);
        if (stopped || failed || interrupted || inputCompleted)
            return;
        if (!track.video && !gst_buffer_get_size(original)) {
            auto* meta = gst_buffer_get_audio_meta(original);
            if (meta && meta->samples)
                return fail();
            auto duration = GST_BUFFER_DURATION(original);
            if (!GST_CLOCK_TIME_IS_VALID(duration) || !duration)
                return;
            if (!GST_BUFFER_FLAG_IS_SET(original, GST_BUFFER_FLAG_GAP) || !GST_BUFFER_PTS_IS_VALID(original))
                return fail();
            GRefPtr event = adoptGRef(gst_event_new_gap(GST_BUFFER_PTS(original), duration));
            return gap(track, event.get());
        }
        if (!bootstrap(track))
            return fail();
        auto pts = GST_BUFFER_PTS(original);
        auto time = gst_segment_to_running_time(&track.segment, GST_FORMAT_TIME, pts);
        if (!GST_CLOCK_TIME_IS_VALID(time))
            return;
        if (GST_CLOCK_TIME_IS_VALID(track.last) && time < track.last)
            return fail();
        if (time == track.last)
            return;
        GRefPtr buffer = adoptGRef(gst_buffer_copy(original));
        if (!buffer || !accountBuffer(buffer.get(), rawBudget, inputBudget))
            return fail();
        GST_BUFFER_PTS(buffer.get()) = time;
        GST_BUFFER_DTS(buffer.get()) = GST_CLOCK_TIME_NONE;
        if (GST_BUFFER_DURATION_IS_VALID(buffer.get())) {
            auto duration = static_cast<long double>(GST_BUFFER_DURATION(buffer.get())) / track.segment.rate;
            if (duration >= GST_CLOCK_TIME_NONE)
                return fail();
            GST_BUFFER_DURATION(buffer.get()) = duration;
        }
        if (!track.video && track.segment.rate != 1) {
            if (auto* meta = gst_buffer_get_audio_meta(buffer.get()))
                gst_structure_get_int(gst_caps_get_structure(track.captureCaps.get(), 0), "rate", &meta->info.rate);
        }
        track.last = time;
        if (!GST_CLOCK_TIME_IS_VALID(track.first))
            track.first = time;
        if (!GST_CLOCK_TIME_IS_VALID(captureStart)) {
            track.pending.append({ WTF::move(buffer), track.captureCaps, std::nullopt });
            startAlignedInput();
        } else
            push(track, WTF::move(buffer), track.captureCaps.get());
    }

    bool initialize(GstElement* playback, bool includeAudio, const IntSize& maximumSize, const String& videoCodec)
    {
        playbackPipeline = playback;
        auto sink = findPlaySink(playback);
        playbackSink = sink;
        if (!sink)
            return false;
        GstElement* selectedVideoSink = nullptr;
        g_object_get(sink.get(), "video-sink", &selectedVideoSink, nullptr);
        GRefPtr videoSink = adoptGRef(selectedVideoSink);
        GRefPtr<GstPad> videoPad;
        GRefPtr<GstPad> audioPad;
        GRefPtr activeVideo = adoptGRef(gst_element_get_static_pad(sink.get(), "video_sink"));
        GRefPtr activeAudio = adoptGRef(gst_element_get_static_pad(sink.get(), "audio_sink"));
        if (activeVideo && videoSink)
            videoPad = adoptGRef(gst_element_get_static_pad(videoSink.get(), "sink"));
        if (includeAudio)
            audioPad = WTF::move(activeAudio);
        for (auto* pad : { &videoPad, &audioPad }) {
            if (*pad) {
                GRefPtr eos = adoptGRef(gst_pad_get_sticky_event(pad->get(), GST_EVENT_EOS, 0));
                if (eos)
                    *pad = nullptr;
            }
        }
        if (!videoPad && !audioPad)
            return false;
        GRefPtr<GstCaps> outputVideoCaps;
        if (videoPad) {
            GRefPtr caps = adoptGRef(gst_pad_get_current_caps(videoPad.get()));
            GstVideoInfo info;
            gst_video_info_init(&info);
            if (!caps || !gst_video_info_from_caps(&info, caps.get()))
                return false;
            auto frameRate = GST_VIDEO_INFO_FPS_N(&info) ? GST_VIDEO_INFO_FPS_N(&info) : 30;
            auto frameScale = GST_VIDEO_INFO_FPS_N(&info) ? GST_VIDEO_INFO_FPS_D(&info) : 1;
            // HLS fragment boundaries require a frame at least once per second.
            if (!frames && frameRate < frameScale)
                frameRate = frameScale = 1;
            videoFrameRate = frameRate;
            videoFrameScale = GST_SECOND * static_cast<uint64_t>(frameScale);
            int width = GST_VIDEO_INFO_WIDTH(&info);
            int height = GST_VIDEO_INFO_HEIGHT(&info);
            if (!maximumSize.isEmpty()) {
                double scale = std::min({ 1.0, static_cast<double>(maximumSize.width()) / width, static_cast<double>(maximumSize.height()) / height });
                width = std::max(2, static_cast<int>(width * scale) / 2 * 2);
                height = std::max(2, static_cast<int>(height * scale) / 2 * 2);
            }
            outputVideoCaps = adoptGRef(gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, frames ? "I420" : "NV12",
                "width", G_TYPE_INT, width, "height", G_TYPE_INT, height,
                "pixel-aspect-ratio", GST_TYPE_FRACTION, GST_VIDEO_INFO_PAR_N(&info), GST_VIDEO_INFO_PAR_D(&info),
                "framerate", GST_TYPE_FRACTION, frameRate, frameScale, nullptr));
            if (frames) {
                auto color = info.colorimetry;
                // JPEG uses full-range BT.601; UT Video's YUV formats encode
                // limited-range BT.601 or BT.709, identified by their FourCC.
                color.range = videoCodec == "jpeg"_s ? GST_VIDEO_COLOR_RANGE_0_255 : GST_VIDEO_COLOR_RANGE_16_235;
                if (videoCodec == "jpeg"_s)
                    color.matrix = GST_VIDEO_COLOR_MATRIX_BT601;
                else if (color.matrix != GST_VIDEO_COLOR_MATRIX_BT601 && color.matrix != GST_VIDEO_COLOR_MATRIX_BT709)
                    color.matrix = GST_VIDEO_COLOR_MATRIX_BT709;
                GUniquePtr<char> colorimetry(gst_video_colorimetry_to_string(&color));
                gst_caps_set_simple(outputVideoCaps.get(), "colorimetry", G_TYPE_STRING, colorimetry.get(), nullptr);
            }
        }
        GRefPtr<GstCaps> outputAudioCaps;
        if (audioPad) {
            GRefPtr caps = adoptGRef(gst_pad_get_current_caps(audioPad.get()));
            gst_audio_info_init(&audioFormat);
            if (!caps || !gst_audio_info_from_caps(&audioFormat, caps.get()))
                return false;
            GstAudioInfo output;
            gst_audio_info_init(&output);
            gst_audio_info_set_format(&output, GST_AUDIO_FORMAT_S16LE, 48000, audioFormat.channels, audioFormat.position);
            outputAudioCaps = adoptGRef(gst_audio_info_to_caps(&output));
        }
        GUniqueOutPtr<GError> error;
        StringBuilder description;
        if (!frames)
            description.append("splitmuxsink name=segments muxer=mpegtsmux sink=appsink max-size-time=1000000000 send-keyframe-requests=true "_s);
        if (videoPad) {
            GRefPtr hardwareEncoder = adoptGRef(gst_element_factory_find("vtenc_h264_hw"));
            description.append("appsrc name=video format=time ! videoconvert ! videoscale ! videorate skip-to-first=true ! capsfilter name=videoformat ! "_s);
            if (videoCodec == "utvideo"_s)
                description.append("avenc_utvideo name=videoencoder ! identity name=videoparser ! appsink name=videooutput sync=false async=false "_s);
            else if (videoCodec == "jpeg"_s)
                description.append("jpegenc name=videoencoder quality=100 ! identity name=videoparser ! appsink name=videooutput sync=false async=false "_s);
            else if (hardwareEncoder)
                description.append("vtenc_h264_hw name=videoencoder realtime=true bitrate=100000 allow-frame-reordering=false max-keyframe-interval-duration=1000000000 ! video/x-h264,profile=baseline "_s);
            else
                description.append("x264enc name=videoencoder speed-preset=ultrafast pass=qual quantizer=10 option-string=aq-mode=1 bitrate=240000 vbv-buf-capacity=1000 key-int-max="_s,
                    std::max<uint64_t>(1, gst_util_uint64_scale_ceil(videoFrameRate, GST_SECOND, videoFrameScale)), " ! video/x-h264,profile=baseline,level=(string)5.2 "_s);
            if (!frames)
                description.append("! h264parse config-interval=-1 name=videoparser ! segments.video "_s);
        }
        if (audioPad) {
            description.append("appsrc name=audio format=time ! audioconvert ! audioresample ! audiorate skip-to-first=true ! capsfilter name=audioformat ! fdkaacenc name=audioencoder header-period=1 ! audio/mpeg,mpegversion=4,profile=lc,stream-format="_s);
            description.append(frames ? "raw ! identity name=audioparser ! appsink name=audiooutput sync=false async=false "_s : "adts ! identity name=audioparser ! segments.audio_0 "_s);
        }
        pipeline = gst_parse_launch(description.toString().utf8().data(), &error.outPtr());
        if (!pipeline || error)
            return false;
        if (outputVideoCaps) {
            GRefPtr format = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), "videoformat"));
            g_object_set(format.get(), "caps", outputVideoCaps.get(), nullptr);
        }
        if (outputAudioCaps) {
            GRefPtr format = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), "audioformat"));
            g_object_set(format.get(), "caps", outputAudioCaps.get(), nullptr);
            GRefPtr encoder = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), "audioencoder"));
            g_object_set(encoder.get(), "bitrate", 160000 * audioFormat.channels, nullptr);
            GRefPtr encoderPad = adoptGRef(gst_element_get_static_pad(encoder.get(), "sink"));
            if (!gst_pad_query_accept_caps(encoderPad.get(), outputAudioCaps.get()))
                return false;
        }
        if (frames) {
            frameGeneration = frames->configure(!!videoPad, !!audioPad);
            for (bool video : { true, false }) {
                if (!(video ? videoPad : audioPad))
                    continue;
                GRefPtr sink = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), video ? "videooutput" : "audiooutput"));
                struct Output { Impl* self; bool video; };
                GstAppSinkCallbacks callbacks { };
                callbacks.new_sample = [](GstAppSink* sink, gpointer data) -> GstFlowReturn {
                    auto& output = *static_cast<Output*>(data);
                    auto& self = *output.self;
                    GRefPtr sample = adoptGRef(gst_app_sink_pull_sample(sink));
                    if (!sample || self.stopped || self.failed || self.interrupted)
                        return GST_FLOW_FLUSHING;
                    auto* buffer = gst_sample_get_buffer(sample.get());
                    auto time = gst_segment_to_running_time(gst_sample_get_segment(sample.get()), GST_FORMAT_TIME, GST_BUFFER_PTS(buffer));
                    GstMappedBuffer mapped(buffer, GST_MAP_READ);
                    if (!mapped || !GST_CLOCK_TIME_IS_VALID(time) || time < self.captureStart) {
                        self.fail();
                        return GST_FLOW_ERROR;
                    }
                    GUniquePtr<char> caps(gst_caps_to_string(gst_sample_get_caps(sample.get())));
                    if (!self.frames->push(self.frameGeneration, output.video, { String::fromUTF8(caps.get()), time - self.captureStart, GST_BUFFER_DURATION_IS_VALID(buffer) ? GST_BUFFER_DURATION(buffer) : 0, SharedBuffer::create(mapped.span<uint8_t>()) })) {
                        self.fail();
                        return GST_FLOW_FLUSHING;
                    }
                    return GST_FLOW_OK;
                };
                gst_app_sink_set_callbacks(GST_APP_SINK(sink.get()), &callbacks, new Output { this, video }, [](gpointer p) { delete static_cast<Output*>(p); });
            }
        } else {
            GRefPtr split = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), "segments"));
            GstElement* rawMux = nullptr;
            GstElement* rawSink = nullptr;
            g_object_get(split.get(), "muxer", &rawMux, "sink", &rawSink, nullptr);
            GRefPtr mux = adoptGRef(rawMux);
            GRefPtr outputSink = adoptGRef(rawSink);
            if (!mux || !outputSink)
                return false;
            auto* program = gst_structure_new("program_map", "PCR_1", G_TYPE_INT, 0x40, nullptr);
            g_object_set(mux.get(), "alignment", 7, "enable-custom-mappings", TRUE, "prog-map", program, nullptr);
            gst_structure_free(program);
            g_object_set(outputSink.get(), "sync", FALSE, "async", FALSE, nullptr);
            GstAppSinkCallbacks sinkCallbacks { };
            sinkCallbacks.new_sample = [](GstAppSink* sink, gpointer data) -> GstFlowReturn {
                auto& self = *static_cast<Impl*>(data);
                GRefPtr sample = adoptGRef(gst_app_sink_pull_sample(sink));
                if (!sample || self.stopped || self.failed || self.interrupted)
                    return GST_FLOW_FLUSHING;
                GstMappedBuffer mapped(gst_sample_get_buffer(sample.get()), GST_MAP_READ);
                std::lock_guard lock(self.outputLock);
                if (!mapped || mapped.size() > outputBudget - self.outputBytes) {
                    self.fail();
                    return GST_FLOW_ERROR;
                }
                self.outputBytes += mapped.size();
                self.output.append(mapped.span<uint8_t>());
                return GST_FLOW_OK;
            };
            gst_app_sink_set_callbacks(GST_APP_SINK(outputSink.get()), &sinkCallbacks, this, nullptr);
        }
        bus = adoptGRef(gst_element_get_bus(pipeline.get()));
        gst_bus_set_sync_handler(bus.get(), [](GstBus*, GstMessage* message, gpointer data) -> GstBusSyncReply {
            static_cast<Impl*>(data)->message(message);
            gst_message_unref(message);
            return GST_BUS_DROP;
        }, this, nullptr);
        for (bool video : { true, false }) {
            auto pad = video ? videoPad : audioPad;
            if (!pad)
                continue;
            auto track = std::make_unique<Track>();
            track->pad = WTF::move(pad);
            track->video = video;
            gst_segment_init(&track->segment, GST_FORMAT_TIME);
            track->source = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), video ? "video" : "audio"));
            g_object_set(track->source.get(), "block", FALSE, "max-bytes", inputBudget, nullptr);
            if (video)
                g_object_set(track->source.get(), "max-buffers", static_cast<guint64>(2), "leaky-type", GST_APP_LEAKY_TYPE_DOWNSTREAM, nullptr);
            GRefPtr parser = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), video ? "videoparser" : "audioparser"));
            GRefPtr parserPad = adoptGRef(gst_element_get_static_pad(parser.get(), "src"));
            if (!video) {
                gst_pad_add_probe(parserPad.get(), GST_PAD_PROBE_TYPE_BUFFER, [](GstPad*, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
                    auto& self = *static_cast<Impl*>(data);
                    // The pinned FDK AAC-LC encoder delays output by two 1024-sample frames.
                    if (self.audioPackets++ < 2)
                        return GST_PAD_PROBE_DROP;
                    auto* buffer = gst_pad_probe_info_get_buffer(info);
                    auto delay = gst_util_uint64_scale(2048, GST_SECOND, 48000);
                    if (!GST_BUFFER_PTS_IS_VALID(buffer) || GST_BUFFER_PTS(buffer) < delay) {
                        self.fail();
                        return GST_PAD_PROBE_DROP;
                    }
                    buffer = gst_buffer_make_writable(buffer);
                    GST_BUFFER_PTS(buffer) -= delay;
                    GST_BUFFER_DTS(buffer) = GST_BUFFER_PTS(buffer);
                    GST_PAD_PROBE_INFO_DATA(info) = buffer;
                    return GST_PAD_PROBE_OK;
                }, this, nullptr);
            }
            gst_pad_add_probe(parserPad.get(), GST_PAD_PROBE_TYPE_BUFFER, [](GstPad* pad, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
                auto& self = *static_cast<Impl*>(data);
                auto* original = gst_pad_probe_info_get_buffer(info);
                GRefPtr event = adoptGRef(gst_pad_get_sticky_event(pad, GST_EVENT_SEGMENT, 0));
                GstSegment segment;
                if (!event || !GST_BUFFER_PTS_IS_VALID(original) || !GST_BUFFER_DURATION_IS_VALID(original)
                    || GST_BUFFER_DURATION(original) >= GST_CLOCK_TIME_NONE - GST_BUFFER_PTS(original)) {
                    self.fail();
                    return GST_PAD_PROBE_DROP;
                }
                gst_event_copy_segment(event.get(), &segment);
                auto end = gst_segment_to_running_time(&segment, GST_FORMAT_TIME, GST_BUFFER_PTS(original) + GST_BUFFER_DURATION(original));
                if (!GST_CLOCK_TIME_IS_VALID(end)) {
                    self.fail();
                    return GST_PAD_PROBE_DROP;
                }
                auto previous = self.encodedEnd.load();
                while (end > previous && !self.encodedEnd.compare_exchange_weak(previous, end)) { }

                auto* buffer = gst_buffer_copy(original);
                if (!buffer || !accountBuffer(buffer, self.encodedBudget, outputBudget)) {
                    if (buffer) gst_buffer_unref(buffer);
                    self.fail();
                    return GST_PAD_PROBE_DROP;
                }
                GST_PAD_PROBE_INFO_DATA(info) = buffer;
                gst_buffer_unref(original);
                return GST_PAD_PROBE_OK;
            }, this, nullptr);
            GRefPtr encoder = adoptGRef(gst_bin_get_by_name(GST_BIN(pipeline.get()), video ? "videoencoder" : "audioencoder"));
            GRefPtr encoderPad = adoptGRef(gst_element_get_static_pad(encoder.get(), "sink"));
            gst_pad_add_probe(encoderPad.get(), GST_PAD_PROBE_TYPE_BUFFER, [](GstPad*, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
                auto& self = *static_cast<Impl*>(data);
                auto* original = gst_pad_probe_info_get_buffer(info);
                auto* buffer = gst_buffer_copy(original);
                if (!buffer || !accountBuffer(buffer, self.normalizedBudget, inputBudget)) {
                    if (buffer) gst_buffer_unref(buffer);
                    self.fail();
                    return GST_PAD_PROBE_DROP;
                }
                GST_PAD_PROBE_INFO_DATA(info) = buffer;
                gst_buffer_unref(original);
                return GST_PAD_PROBE_OK;
            }, this, nullptr);
            tracks.append(WTF::move(track));
        }
        if (gst_element_set_state(pipeline.get(), GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
            return false;
        struct Probe { std::shared_ptr<Impl> capture; Track* track; };
        for (auto& track : tracks) {
            track->probe = gst_pad_add_probe(track->pad.get(), static_cast<GstPadProbeType>(GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_BUFFER_LIST | GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | GST_PAD_PROBE_TYPE_EVENT_FLUSH), [](GstPad*, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
                auto& probe = *static_cast<Probe*>(data);
                auto& self = *probe.capture;
                auto& track = *probe.track;
                if (self.stopped || self.failed)
                    return GST_PAD_PROBE_OK;
                if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER)
                    self.sample(track, gst_pad_probe_info_get_buffer(info));
                else if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER_LIST) {
                    auto* list = gst_pad_probe_info_get_buffer_list(info);
                    for (unsigned i = 0; i < gst_buffer_list_length(list); ++i)
                        self.sample(track, gst_buffer_list_get(list, i));
                } else {
                    auto* event = gst_pad_probe_info_get_event(info);
                    switch (GST_EVENT_TYPE(event)) {
                    case GST_EVENT_STREAM_START:
                    case GST_EVENT_CAPS:
                    case GST_EVENT_SEGMENT:
                    case GST_EVENT_FLUSH_START:
                    case GST_EVENT_FLUSH_STOP:
                        self.streamEvent(track, event);
                        break;
                    case GST_EVENT_GAP: {
                        std::lock_guard lock(self.eventLock);
                        self.gap(track, event);
                        break;
                    }
                    case GST_EVENT_EOS:
                        self.streamEvent(track, event);
                        break;
                    default:
                        break;
                    }
                }
                return GST_PAD_PROBE_OK;
            }, new Probe { shared_from_this(), track.get() }, [](gpointer data) { delete static_cast<Probe*>(data); });
        }
        for (size_t i = 0; i < tracks.size(); ++i) {
            struct Check { std::weak_ptr<Impl> self; size_t index; };
            gst_pad_add_probe(tracks[i]->pad.get(), GST_PAD_PROBE_TYPE_IDLE, [](GstPad* pad, GstPadProbeInfo*, gpointer data) -> GstPadProbeReturn {
                auto& check = *static_cast<Check*>(data);
                if (auto self = check.self.lock(); self && !self->stopped) {
                    GRefPtr eos = adoptGRef(gst_pad_get_sticky_event(pad, GST_EVENT_EOS, 0));
                    if (eos) {
                        self->streamEvent(*self->tracks[check.index], eos.get());
                    }
                }
                return GST_PAD_PROBE_REMOVE;
            }, new Check { shared_from_this(), i }, [](gpointer data) { delete static_cast<Check*>(data); });
        }
        auto destroy = +[](gpointer data, GClosure*) { delete static_cast<std::shared_ptr<Impl>*>(data); };
        auto padAddedToSink = +[](GstElement*, GstPad* pad, gpointer data) {
            auto self = *static_cast<std::shared_ptr<Impl>*>(data);
            if (strcmp(GST_PAD_NAME(pad), "video_sink") && strcmp(GST_PAD_NAME(pad), "audio_sink"))
                return;
            if (!self->inputCompleted) {
                self->fail();
                return;
            }
            gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, [](GstPad*, GstPadProbeInfo* info, gpointer data) -> GstPadProbeReturn {
                if (GST_EVENT_TYPE(gst_pad_probe_info_get_event(info)) != GST_EVENT_STREAM_START)
                    return GST_PAD_PROBE_OK;
                static_cast<std::shared_ptr<Impl>*>(data)->get()->continueAfterEnd();
                return GST_PAD_PROBE_REMOVE;
            }, new std::shared_ptr<Impl>(WTF::move(self)), [](gpointer data) { delete static_cast<std::shared_ptr<Impl>*>(data); });
        };
        auto padRemovedFromSink = +[](GstElement*, GstPad* pad, gpointer data) {
            auto self = *static_cast<std::shared_ptr<Impl>*>(data);
            if (!self->inputCompleted && (!strcmp(GST_PAD_NAME(pad), "video_sink") || !strcmp(GST_PAD_NAME(pad), "audio_sink")))
                self->fail();
        };
        padAdded = g_signal_connect_data(playbackSink.get(), "pad-added", G_CALLBACK(padAddedToSink), new std::shared_ptr<Impl>(shared_from_this()), destroy, G_CONNECT_DEFAULT);
        padRemoved = g_signal_connect_data(playbackSink.get(), "pad-removed", G_CALLBACK(padRemovedFromSink), new std::shared_ptr<Impl>(shared_from_this()), destroy, G_CONNECT_DEFAULT);
        sinkRemoved = g_signal_connect_data(playback, "deep-element-removed", G_CALLBACK(+[](GstBin*, GstBin*, GstElement* element, gpointer data) {
            auto self = *static_cast<std::shared_ptr<Impl>*>(data);
            if (!self->inputCompleted) {
                for (auto& track : self->tracks) {
                    if (gst_object_has_as_ancestor(GST_OBJECT(track->pad.get()), GST_OBJECT(element)))
                        self->fail();
                }
            }
        }), new std::shared_ptr<Impl>(shared_from_this()), destroy, G_CONNECT_DEFAULT);
        return true;
    }

    bool finishInput()
    {
        std::lock_guard lock(eventLock);
        if (stopped || failed || interrupted)
            return false;
        if (inputCompleted.exchange(true))
            return true;
        for (auto& track : tracks)
            track->ended = true;
        startAlignedInput();
        return true;
    }

    void stop()
    {
        if (stopped.exchange(true))
            return;
        {
            std::lock_guard lock(deliveryLock);
            deliveryAvailable.notify_all();
        }
        if (frames)
            frames->cancel(frameGeneration);
        if (padAdded)
            g_signal_handler_disconnect(playbackSink.get(), std::exchange(padAdded, 0));
        if (padRemoved)
            g_signal_handler_disconnect(playbackSink.get(), std::exchange(padRemoved, 0));
        if (sinkRemoved)
            g_signal_handler_disconnect(playbackPipeline.get(), std::exchange(sinkRemoved, 0));
        for (auto& track : tracks) {
            if (auto probe = std::exchange(track->probe, 0))
                gst_pad_remove_probe(track->pad.get(), probe);
        }
        if (pipeline) {
            WorkQueue::create("Media restream teardown"_s)->dispatch([self = shared_from_this()] {
                gst_element_set_state(self->pipeline.get(), GST_STATE_NULL);
                if (self->bus)
                    gst_bus_set_sync_handler(self->bus.get(), nullptr, nullptr, nullptr);
                callOnMainThread([self] { self->callbacks = { }; });
            });
        }
    }
};

MediaRestreamCapture::MediaRestreamCapture(std::shared_ptr<Impl>&& impl) : m_impl(WTF::move(impl)) { }
MediaRestreamCapture::~MediaRestreamCapture() { stop(); }
void MediaRestreamCapture::stop() { m_impl->stop(); }
bool MediaRestreamCapture::finishInput() { return m_impl->finishInput(); }
bool MediaRestreamCapture::inputEnded() const { return m_impl->inputCompleted; }
std::shared_ptr<MediaRestreamCapture> MediaRestreamCapture::create(GstElement* playback, Callbacks&& callbacks, bool includeAudio, const IntSize& maximumSize, const String& videoCodec, std::shared_ptr<MediaRestreamFrameQueue> frames)
{
    auto impl = std::make_shared<Impl>();
    impl->callbacks = WTF::move(callbacks);
    impl->frames = WTF::move(frames);
    if (!impl->initialize(playback, includeAudio, maximumSize, videoCodec)) {
        impl->stop();
        return nullptr;
    }
    return std::shared_ptr<MediaRestreamCapture>(new MediaRestreamCapture(WTF::move(impl)));
}
}
