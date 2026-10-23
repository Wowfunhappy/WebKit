#pragma once

#include <WebCore/SharedBuffer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/URL.h>
#include <memory>

namespace WebKit {
class MediaRestreamRTSP {
public:
    using Reply = CompletionHandler<void(String&&, uint64_t, uint64_t, RefPtr<WebCore::SharedBuffer>&&)>;
    using Read = Function<void(bool video, Reply&&)>;
    static std::shared_ptr<MediaRestreamRTSP> create(const String& description, const String& path, Read&&);
    ~MediaRestreamRTSP();
    URL url() const;
private:
    struct Impl;
    explicit MediaRestreamRTSP(std::shared_ptr<Impl>&&);
    std::shared_ptr<Impl> m_impl;
};
}
