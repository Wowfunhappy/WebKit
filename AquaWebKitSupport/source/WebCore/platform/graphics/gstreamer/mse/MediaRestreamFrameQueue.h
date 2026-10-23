#pragma once

#include <WebCore/SharedBuffer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/MainThread.h>
#include <wtf/JSONValues.h>
#include <array>
#include <condition_variable>
#include <deque>
#include <mutex>

namespace WebCore {
// Encoded frames cross the process boundary on demand; encoder threads supply backpressure.
class MediaRestreamFrameQueue {
public:
    struct Frame {
        String caps;
        uint64_t time { 0 };
        uint64_t duration { 0 };
        RefPtr<SharedBuffer> data;
    };
    using Reader = CompletionHandler<void(Frame&&)>;
    Function<void()> ready;

    uint64_t configure(bool video, bool audio)
    {
        std::lock_guard lock(m_lock);
        m_tracks[0].active = video;
        m_tracks[1].active = audio;
        m_origin = std::max(m_tracks[0].end, m_tracks[1].end);
        ++m_generation;
        m_space.notify_all();
        return m_generation;
    }
    void cancel(uint64_t generation)
    {
        std::lock_guard lock(m_lock);
        if (generation == m_generation)
            ++m_generation;
        m_space.notify_all();
    }
    bool push(uint64_t generation, bool video, Frame&& frame)
    {
        std::unique_lock lock(m_lock);
        auto& track = m_tracks[video ? 0 : 1];
        auto size = frame.data->size();
        if (size > budget)
            return false;
        m_space.wait(lock, [&] { return m_stopped || generation != m_generation || track.bytes <= budget - size; });
        if (m_stopped || generation != m_generation)
            return false;
        frame.time += m_origin;
        track.end = std::max(track.end, frame.time + frame.duration);
        track.caps = frame.caps.isolatedCopy();
        if (!m_ready && std::all_of(m_tracks.begin(), m_tracks.end(), [](auto& track) { return !track.active || !track.caps.isEmpty(); })) {
            m_ready = true;
            callOnMainThread(WTF::move(ready));
        }
        if (track.reader) {
            auto reader = std::exchange(track.reader, std::nullopt);
            callOnMainThread([reader = WTF::move(*reader), frame = WTF::move(frame)]() mutable { reader(WTF::move(frame)); });
        } else {
            track.bytes += size;
            track.frames.push_back(WTF::move(frame));
        }
        return true;
    }
    String description()
    {
        std::lock_guard lock(m_lock);
        auto result = JSON::Object::create();
        result->setString("video"_s, m_tracks[0].caps);
        result->setString("audio"_s, m_tracks[1].caps);
        return result->toJSONString();
    }
    void next(bool video, Reader&& reader)
    {
        std::unique_lock lock(m_lock);
        auto& track = m_tracks[video ? 0 : 1];
        if (!track.frames.empty()) {
            auto frame = WTF::move(track.frames.front());
            track.frames.pop_front();
            track.bytes -= frame.data->size();
            m_space.notify_all();
            lock.unlock();
            return reader(WTF::move(frame));
        }
        if (m_stopped || m_ended || !track.active || track.reader) {
            lock.unlock();
            return reader({ });
        }
        track.reader = WTF::move(reader);
    }
    void finish(bool stop = false)
    {
        std::lock_guard lock(m_lock);
        m_ended = true;
        m_stopped |= stop;
        for (auto& track : m_tracks) {
            if (stop) {
                track.frames.clear();
                track.bytes = 0;
            }
            if (auto reader = std::exchange(track.reader, std::nullopt))
                callOnMainThread([reader = WTF::move(*reader)]() mutable { reader({ }); });
        }
        m_space.notify_all();
    }
private:
    static constexpr uint64_t budget = 64 * 1024 * 1024;
    struct Track {
        bool active { false };
        String caps;
        uint64_t bytes { 0 };
        uint64_t end { 0 };
        std::deque<Frame> frames;
        std::optional<Reader> reader;
    };
    std::array<Track, 2> m_tracks;
    std::mutex m_lock;
    std::condition_variable m_space;
    uint64_t m_origin { 0 };
    uint64_t m_generation { 0 };
    bool m_ready { false };
    bool m_ended { false };
    bool m_stopped { false };
};
}
