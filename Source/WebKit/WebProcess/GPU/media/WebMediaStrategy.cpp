// MAVERICKS_BACKPORT: minimal WebMediaStrategy implementation. The original WK2 file
// stages everything through GPU process; on this MAVERICKS_BACKPORT GPU process is
// disabled, so we route createAudioDestination directly to AudioDestination::create
// like WebKitLegacy does. Without this, the polyfill-supplied empty vtable for
// WebMediaStrategy left createAudioDestination as a NULL function pointer, crashing
// at the call site in DefaultAudioDestinationNode::createDestination.
// MAVERICKS_BACKPORT: trimmed includes — the GPU-process/remote-proxy headers are gone with the GPU path.
#include "config.h"
#include "WebMediaStrategy.h"

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "GPUConnectionToWebProcess.h"
#include "GPUProcessConnection.h"
#include "RemoteAudioDestinationProxy.h"
#include "RemoteCDMFactory.h"
#include "RemoteVideoFrameObjectHeapProxy.h"
#include "WebProcess.h"
MAVERICKS_BACKPORT */
#include <WebCore/AudioDestination.h>
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #include <WebCore/AudioIOCallback.h>
// #include <WebCore/CDMFactory.h>
// #include <WebCore/MediaPlayer.h>
// (end MAVERICKS_BACKPORT restored block)
#include <WebCore/NowPlayingManager.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// using namespace WebCore;
// (end MAVERICKS_BACKPORT restored block)

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebMediaStrategy);

WebMediaStrategy::~WebMediaStrategy() = default;

#if ENABLE(WEB_AUDIO)
Ref<WebCore::AudioDestination> WebMediaStrategy::createAudioDestination(const WebCore::AudioDestinationCreationOptions& options)
{
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    ASSERT(isMainRunLoop());
#if ENABLE(GPU_PROCESS)
    if (m_useGPUProcess)
        return WebCore::SharedAudioDestination::create(options, [] (auto& options) {
            return RemoteAudioDestinationProxy::create(options);
        });
#endif
MAVERICKS_BACKPORT */
    return WebCore::AudioDestination::create(options);
}
#endif

// MAVERICKS_BACKPORT: GPU process is disabled, so use the in-process NowPlayingManager directly.
std::unique_ptr<WebCore::NowPlayingManager> WebMediaStrategy::createNowPlayingManager() const
{
    return makeUnique<WebCore::NowPlayingManager>();
}

bool WebMediaStrategy::hasThreadSafeMediaSourceSupport() const
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #if ENABLE(GPU_PROCESS)
//     return m_useGPUProcess;
// #else
// (end MAVERICKS_BACKPORT restored block)
    return false;
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #endif
// (end MAVERICKS_BACKPORT restored block)
}

#if ENABLE(MEDIA_SOURCE)
void WebMediaStrategy::enableMockMediaSource()
{
// MAVERICKS_BACKPORT: mock-media-source registration was a GPU-process/testing path; no-op here.
}
#endif
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     m_mockMediaSourceEnabled = true;
// (end MAVERICKS_BACKPORT restored block)

#if PLATFORM(COCOA) && ENABLE(VIDEO)
// MAVERICKS_BACKPORT: native-image extraction ran in the GPU process video-frame heap; that path is gone, so report none.
void WebMediaStrategy::nativeImageFromVideoFrame(const WebCore::VideoFrame&, CompletionHandler<void(std::optional<RefPtr<WebCore::NativeImage>>&&)>&& completion)
{
    completion(std::nullopt);
}
#endif

#if ENABLE(VIDEO) && ENABLE(GPU_PROCESS)
// MAVERICKS_BACKPORT: GPU process is disabled; remote renderer is unavailable, so create returns null.
RefPtr<WebCore::AudioVideoRenderer> WebMediaStrategy::createAudioVideoRenderer(LoggerHelper*, WebCore::HTMLMediaElementIdentifier, WebCore::MediaPlayerIdentifier) const
{
    return nullptr;
}
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #endif
// (end MAVERICKS_BACKPORT restored block)

// MAVERICKS_BACKPORT: extended-type decode probing went through the GPU process, which is disabled here; report unsupported.
bool WebMediaStrategy::canDecodeExtendedType(WebCore::PlatformMediaDecodingType, const WebCore::ContentType&)
{
    return false;
}
#endif

} // namespace WebKit
