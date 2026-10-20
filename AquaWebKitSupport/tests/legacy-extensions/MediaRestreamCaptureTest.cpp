#include "config.h"
#include "MediaRestreamCapture.h"
#include <wtf/MainThread.h>
#include <CoreFoundation/CoreFoundation.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <thread>

using namespace WebCore;
template class WebCore::GstBufferMapper<GstMapInfo, gst_buffer_map, gst_buffer_unmap>;

static std::optional<unsigned> aacChannels(std::span<const uint8_t> transport)
{
    std::optional<unsigned> audioPID;
    Vector<uint8_t> audio;
    for (size_t offset = 0; offset + 188 <= transport.size(); offset += 188) {
        auto packet = transport.subspan(offset, 188);
        if (packet[0] != 0x47 || !(packet[3] & 0x10))
            continue;
        unsigned pid = ((packet[1] & 31) << 8) | packet[2];
        size_t begin = 4;
        if (packet[3] & 0x20)
            begin += 1 + packet[4];
        if (begin >= packet.size())
            continue;
        auto payload = packet.subspan(begin);
        if (packet[1] & 0x40) {
            if (payload.size() < 9 || payload[0] || payload[1] || payload[2] != 1 || payload[3] < 0xc0 || payload[3] > 0xdf)
                continue;
            audioPID = pid;
            if (9 + payload[8] > payload.size())
                continue;
            payload = payload.subspan(9 + payload[8]);
        }
        if (audioPID == pid)
            audio.append(payload);
    }
    for (size_t offset = 0; offset + 7 <= audio.size(); ++offset) {
        if (audio[offset] != 0xff || (audio[offset + 1] & 0xf6) != 0xf0)
            continue;
        auto channels = ((audio[offset + 2] & 1) << 2) | (audio[offset + 3] >> 6);
        auto length = ((audio[offset + 3] & 3) << 11) | (audio[offset + 4] << 3) | (audio[offset + 5] >> 5);
        if (channels && length >= 7 && offset + length <= audio.size())
            return channels;
    }
    return std::nullopt;
}

int main(int argc, char** argv)
{
    if (argc != 3)
        return 2;
    WTF::initializeMainThread();
    gst_init(nullptr, nullptr);
    GError* error = nullptr;
    auto* playback = gst_parse_launch(argv[1], &error);
    if (!playback || error) {
        fprintf(stderr, "Pipeline: %s\n", error ? error->message : "unavailable");
        return 2;
    }
    auto* sink = gst_bin_get_by_name(GST_BIN(playback), "ps");
    for (auto name : { "video_sink", "audio_sink" }) {
        auto* pad = gst_element_get_static_pad(sink, name);
        if (!pad)
            continue;
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, [](GstPad*, GstPadProbeInfo* info, gpointer) -> GstPadProbeReturn {
            auto* event = gst_pad_probe_info_get_event(info);
            if (GST_EVENT_TYPE(event) == GST_EVENT_STREAM_START) {
                event = gst_event_make_writable(event);
                gst_event_set_group_id(event, 1);
                GST_PAD_PROBE_INFO_DATA(info) = event;
            }
            return GST_PAD_PROBE_OK;
        }, nullptr, nullptr);
        gst_object_unref(pad);
    }
    gst_object_unref(sink);
    gst_element_set_state(playback, GST_STATE_PAUSED);
    if (gst_element_get_state(playback, nullptr, nullptr, 10 * GST_SECOND) != GST_STATE_CHANGE_SUCCESS)
        return 2;
    bool done = false;
    bool failed = false;
    bool reachedEnd = false;
    bool continuedAfterEnd = false;
    bool expectContinuation = getenv("CAPTURE_POST_EOS_STREAM_START");
    unsigned expectedChannels = getenv("CAPTURE_EXPECT_CHANNELS") ? atoi(getenv("CAPTURE_EXPECT_CHANNELS")) : 0;
    std::optional<unsigned> observedChannels;
    unsigned count = 0;
    uint64_t bytes = 0;
    double lastEnd = 0;
    unsigned consumerDelay = getenv("CAPTURE_CONSUMER_DELAY") ? atoi(getenv("CAPTURE_CONSUMER_DELAY")) : 0;
    struct Delivery {
        std::chrono::steady_clock::time_point ready;
        Ref<SharedBuffer> data;
        CompletionHandler<void()> completion;
    };
    std::deque<Delivery> deliveries;
    auto capture = MediaRestreamCapture::create(playback, {
        [&](double start, double end, double rate, double offset, Ref<SharedBuffer>&& data, CompletionHandler<void()>&& completion) {
            auto payload = data->span();
            bool valid = std::isfinite(start) && std::isfinite(end) && end > start && std::round(end - start) <= 3
                && std::isfinite(rate) && rate > 0 && std::isfinite(offset)
                && (!count || std::abs(start - lastEnd) < .000001) && !payload.empty() && !(payload.size() % 188);
            for (size_t i = 0; i < payload.size(); i += 188)
                valid &= payload[i] == 0x47;
            if (expectedChannels) {
                if (auto channels = aacChannels(payload)) {
                    valid &= !observedChannels || *observedChannels == *channels;
                    observedChannels = *channels;
                }
            }
            if (!valid) {
                fprintf(stderr, "Invalid fragment %u: %.9f..%.9f, previous %.9f, %zu bytes\n", count, start, end, lastEnd, payload.size());
                failed = done = true;
            }
            ++count;
            bytes += payload.size();
            lastEnd = end;
            if (consumerDelay)
                deliveries.push_back({ std::chrono::steady_clock::now() + std::chrono::seconds(consumerDelay), WTF::move(data), WTF::move(completion) });
            else
                completion();
        },
        [&] {
            if (expectContinuation)
                reachedEnd = true;
            else
                done = true;
        },
        [&] {
            if (expectContinuation && reachedEnd) {
                continuedAfterEnd = done = true;
                return;
            }
            fprintf(stderr, "Unexpected capture interruption\n");
            failed = done = true;
        },
        [&] { fprintf(stderr, "Capture failure\n"); failed = done = true; }
    }, true, { });
    if (!capture)
        return 3;
    if (getenv("CAPTURE_INITIAL_GAPS")) {
        auto* delay = gst_bin_get_by_name(GST_BIN(playback), "startupDelay");
        g_object_set(delay, "sleep-time", static_cast<guint>(5000000), nullptr);
        gst_object_unref(delay);
    }
    gst_element_set_state(playback, GST_STATE_PLAYING);
    if (getenv("CAPTURE_INITIAL_GAPS")) {
        auto* sink = gst_bin_get_by_name(GST_BIN(playback), "ps");
        GstElement* audio = nullptr;
        g_object_get(sink, "audio-sink", &audio, nullptr);
        auto* pad = gst_element_get_static_pad(audio, "sink");
        for (unsigned i = 0; i < 600; ++i) {
            gst_pad_send_event(pad, gst_event_new_gap(i * GST_MSECOND, GST_MSECOND));
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
            if (failed) {
                fprintf(stderr, "Failed after %u initial gaps\n", i + 1);
                break;
            }
        }
        gst_object_unref(pad);
        gst_object_unref(audio);
        gst_object_unref(sink);
        auto* delay = gst_bin_get_by_name(GST_BIN(playback), "startupDelay");
        g_object_set(delay, "sleep-time", static_cast<guint>(0), nullptr);
        gst_object_unref(delay);
    }
    auto started = std::chrono::steady_clock::now();
    auto deadline = started + std::chrono::seconds(atoi(argv[2]));
    auto report = started + std::chrono::seconds(30);
    bool stalled = false;
    bool cancelled = false;
    bool continuationSent = false;
    unsigned stallSeconds = getenv("CAPTURE_MAIN_STALL") ? atoi(getenv("CAPTURE_MAIN_STALL")) : 0;
    while ((!done || !deliveries.empty()) && std::chrono::steady_clock::now() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .02, true);
        while (!deliveries.empty() && deliveries.front().ready <= std::chrono::steady_clock::now()) {
            deliveries.front().completion();
            deliveries.pop_front();
        }
        if (expectContinuation && reachedEnd && !continuationSent) {
            continuationSent = true;
            auto* sink = gst_bin_get_by_name(GST_BIN(playback), "ps");
            GstElement* selected = nullptr;
            g_object_get(sink, "video-sink", &selected, nullptr);
            if (!selected)
                g_object_get(sink, "audio-sink", &selected, nullptr);
            auto* pad = selected ? gst_element_get_static_pad(selected, "sink") : nullptr;
            auto* peer = pad ? gst_pad_get_peer(pad) : nullptr;
            auto* event = gst_event_new_stream_start("post-eos-stream");
            gst_event_set_group_id(event, 2);
            if (!peer || !gst_pad_push_event(peer, event))
                failed = done = true;
            if (peer)
                gst_object_unref(peer);
            if (pad)
                gst_object_unref(pad);
            if (selected)
                gst_object_unref(selected);
            gst_object_unref(sink);
        }
        if (stallSeconds && !stalled && std::chrono::steady_clock::now() - started > std::chrono::seconds(5)) {
            stalled = true;
            fprintf(stderr, "Main thread stall: %u seconds\n", stallSeconds);
            std::this_thread::sleep_for(std::chrono::seconds(stallSeconds));
            if (getenv("CAPTURE_CANCEL_AFTER_STALL")) {
                capture->stop();
                cancelled = done = true;
            }
        }
        if (std::chrono::steady_clock::now() >= report) {
            fprintf(stderr, "Progress: %u fragments, %.3f seconds, %llu bytes\n", count, lastEnd, static_cast<unsigned long long>(bytes));
            report += std::chrono::seconds(30);
        }
    }
    capture->stop();
    for (auto& delivery : deliveries)
        delivery.completion();
    deliveries.clear();
    gst_element_set_state(playback, GST_STATE_NULL);
    gst_object_unref(playback);
    for (unsigned i = 0; i < 10; ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .02, true);
    bool success = !failed && done && count && (!getenv("CAPTURE_CANCEL_AFTER_STALL") || cancelled) && (!expectContinuation || continuedAfterEnd)
        && (!expectedChannels || observedChannels == expectedChannels);
    fprintf(stderr, "%s: %u fragments, %.3f seconds, %llu bytes\n", success ? "PASS" : "FAIL", count, lastEnd, static_cast<unsigned long long>(bytes));
    return !success;
}
