#include "config.h"
#include "MediaRestreamFrameQueue.h"
#include <wtf/MainThread.h>
#include <CoreFoundation/CoreFoundation.h>
#include <future>
#include <thread>

using namespace WebCore;

int main()
{
    WTF::initializeMainThread();
    MediaRestreamFrameQueue queue;
    unsigned ready = 0;
    queue.ready = [&] { ++ready; };
    auto generation = queue.configure(true, false);
    Vector<uint8_t> bytes;
    bytes.grow(64 * 1024 * 1024);
    RELEASE_ASSERT(queue.push(generation, true, { "image/jpeg"_s, 100, 30, SharedBuffer::create(WTF::move(bytes)) }));
    std::promise<void> started;
    std::promise<bool> pushed;
    auto result = pushed.get_future();
    std::thread producer([&] {
        started.set_value();
        uint8_t value = 1;
        pushed.set_value(queue.push(generation, true, { "image/jpeg"_s, 130, 30, SharedBuffer::create(std::span<const uint8_t> { &value, 1 }) }));
    });
    started.get_future().wait();
    RELEASE_ASSERT(result.wait_for(std::chrono::milliseconds(50)) == std::future_status::timeout);
    queue.cancel(generation);
    RELEASE_ASSERT(result.wait_for(std::chrono::seconds(2)) == std::future_status::ready && !result.get());
    producer.join();
    auto nextGeneration = queue.configure(true, false);
    queue.cancel(generation); // Retiring the old encoder cannot cancel its replacement.
    queue.next(true, [](auto&& frame) { RELEASE_ASSERT(frame.data && frame.data->size() == 64 * 1024 * 1024 && frame.time == 100); });
    uint8_t value = 2;
    RELEASE_ASSERT(queue.push(nextGeneration, true, { "image/jpeg"_s, 10, 30, SharedBuffer::create(std::span<const uint8_t> { &value, 1 }) }));
    queue.next(true, [](auto&& frame) { RELEASE_ASSERT(frame.data && frame.time == 140); });
    bool cancelled = false;
    queue.next(true, [&](auto&& frame) { RELEASE_ASSERT(!frame.data); cancelled = true; });
    queue.finish(true);
    for (unsigned i = 0; i < 100 && !cancelled; ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .01, true);
    RELEASE_ASSERT(cancelled && ready == 1);
    RELEASE_ASSERT(!queue.push(nextGeneration, true, { "image/jpeg"_s, 0, 1, SharedBuffer::create(std::span<const uint8_t> { &value, 1 }) }));
    puts("PASS: bounded queue, generation cancellation, timeline continuation, pending-reader shutdown");
}
