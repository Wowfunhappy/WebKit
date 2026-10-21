#pragma once

#include <wtf/Expected.h>
#include <wtf/CompletionHandler.h>
#include <wtf/URL.h>
#include <wtf/NeverDestroyed.h>
#include <memory>

namespace IPC { class Connection; }
namespace WebKit {
class WebPageProxy;
class MediaRestreamRTSP;
class WebProcessProxy;
class MediaRestreamServer {
public:
    static MediaRestreamServer& singleton();
    void open(WebPageProxy&, WebProcessProxy&, uint64_t, const String& application, const URL& directURL, const String& playlist, const String& title, const String& adapter, const String& captureCodec, double position, double rate, bool paused, CompletionHandler<void(Expected<URL, String>&&)>&&, std::shared_ptr<MediaRestreamRTSP> = nullptr);
    String prepareHandoff(WebPageProxy&, WebProcessProxy&, const String& extensionKey);
    bool claimHandoff(WebPageProxy&, WebProcessProxy&, const String& ticket, const String& extensionKey, uint64_t request);
    void cancelHandoff(const String& ticket, const String& extensionKey);
    void cancelPreparedHandoffs(const WebPageProxy&);
    void cancelPreparedHandoffs(const String& extensionKey);
    bool beginHandoff(WebPageProxy&, WebProcessProxy&, uint64_t);
    bool hasHandoff(const WebPageProxy&, IPC::Connection&, uint64_t) const;
    void endHandoff(IPC::Connection&, uint64_t);
    void complete(IPC::Connection&, uint64_t);
    void end(IPC::Connection&, uint64_t);
    void control(IPC::Connection&, uint64_t, const String&, double, CompletionHandler<void(bool)>&&);
    void activate(IPC::Connection&, uint64_t, CompletionHandler<void(Expected<bool, String>&&)>&&);
    bool detachPage(WebPageProxy&);
    bool isDetached(const WebPageProxy&) const;
    bool ownsPage(const WebPageProxy&) const;
    void processTerminated(WebProcessProxy&);
private:
    friend class NeverDestroyed<MediaRestreamServer>;
    MediaRestreamServer();
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
}
