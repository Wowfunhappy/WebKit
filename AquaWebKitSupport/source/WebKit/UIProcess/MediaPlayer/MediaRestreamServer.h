#pragma once

#include <wtf/Expected.h>
#include <wtf/CompletionHandler.h>
#include <wtf/URL.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RefPtr.h>
#include <memory>

namespace IPC { class Connection; }
namespace WebCore { class SharedBuffer; }
namespace WebKit {
class WebPageProxy;
class MediaRestreamRTSP;
class WebProcessProxy;
class MediaRestreamServer {
public:
    static MediaRestreamServer& singleton();
    void publish(WebPageProxy&, WebProcessProxy&, uint64_t, const URL& directURL, const String& playlist, const String& title, const String& captureCodec, CompletionHandler<void(Expected<URL, String>&&)>&&, std::shared_ptr<MediaRestreamRTSP> = nullptr);
    void open(IPC::Connection&, uint64_t, const String& application, const String& adapter, double timeout, CompletionHandler<void(Expected<URL, String>&&)>&&);
    void state(IPC::Connection&, uint64_t, CompletionHandler<void(Expected<String, String>&&)>&&);
    void setResource(IPC::Connection&, uint64_t, const String& name, const String& type, RefPtr<WebCore::SharedBuffer>&&, CompletionHandler<void(Expected<URL, String>&&)>&&);
    bool setPlaylistProvider(IPC::Connection&, uint64_t, bool);
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
