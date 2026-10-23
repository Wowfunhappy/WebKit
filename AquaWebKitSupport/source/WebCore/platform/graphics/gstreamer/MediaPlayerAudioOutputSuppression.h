#pragma once

#include <atomic>
#include <memory>
#include <gst/gst.h>

namespace WebCore {
class MediaPlayerAudioOutputSuppression {
public:
    void configureSink(GstElement*);
    void setSuppressed(bool suppressed) { m_suppressed->store(suppressed); }
private:
    std::shared_ptr<std::atomic<bool>> m_suppressed { std::make_shared<std::atomic<bool>>(false) };
};
}
