#pragma once

#include "GStreamerCommon.h"
#include "MediaRestreamFrameQueue.h"
#include <WebCore/IntSize.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/Function.h>
#include <wtf/CompletionHandler.h>
#include <memory>

namespace WebCore {
class MediaRestreamCapture final {
public:
    struct Callbacks {
        Function<void(double, double, double, double, Ref<SharedBuffer>&&, CompletionHandler<void()>&&)> fragment;
        Function<void()> ended;
        Function<void()> interrupted;
        Function<void()> failed;
    };
    static std::shared_ptr<MediaRestreamCapture> create(GstElement*, Callbacks&&, bool includeAudio = true, const IntSize& maximumSize = { }, const String& videoCodec = { }, std::shared_ptr<MediaRestreamFrameQueue> = nullptr);
    ~MediaRestreamCapture();
    void stop();
    bool finishInput();
    bool inputEnded() const;
private:
    struct Impl;
    explicit MediaRestreamCapture(std::shared_ptr<Impl>&&);
    std::shared_ptr<Impl> m_impl;
};
}
