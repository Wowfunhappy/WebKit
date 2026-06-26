// MAVERICKS_BACKPORT: minimal WebMediaStrategy implementation. The original WK2 file
// stages everything through GPU process; on this MAVERICKS_BACKPORT GPU process is
// disabled, so we route createAudioDestination directly to AudioDestination::create
// like WebKitLegacy does. Without this, the polyfill-supplied empty vtable for
// WebMediaStrategy left createAudioDestination as a NULL function pointer, crashing
// at the call site in DefaultAudioDestinationNode::createDestination.
#include "config.h"
#include "WebMediaStrategy.h"

// MAVERICKS_BACKPORT: trimmed includes — the GPU-process/remote-proxy headers are gone with the GPU path.
#include <WebCore/AudioDestination.h>
#include <WebCore/NowPlayingManager.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebMediaStrategy);

WebMediaStrategy::~WebMediaStrategy() = default;

#if ENABLE(WEB_AUDIO)
Ref<WebCore::AudioDestination> WebMediaStrategy::createAudioDestination(const WebCore::AudioDestinationCreationOptions& options)
{
    return WebCore::AudioDestination::create(options);
}
#endif

// MAVERICKS_BACKPORT: GPU process is disabled, so use the in-process NowPlayingManager directly.
std::unique_ptr<WebCore::NowPlayingManager> WebMediaStrategy::createNowPlayingManager() const
{
    return makeUnique<WebCore::NowPlayingManager>();
}

// MAVERICKS_BACKPORT: thread-safe MediaSource support depended on the GPU process; report none.
bool WebMediaStrategy::hasThreadSafeMediaSourceSupport() const
{
    return false;
}

#if ENABLE(MEDIA_SOURCE)
// MAVERICKS_BACKPORT: mock-media-source registration was a GPU-process/testing path; no-op here.
void WebMediaStrategy::enableMockMediaSource()
{
}
#endif

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

// MAVERICKS_BACKPORT: extended-type decode probing went through the GPU process, which is disabled here; report unsupported.
bool WebMediaStrategy::canDecodeExtendedType(WebCore::PlatformMediaDecodingType, const WebCore::ContentType&)
{
    return false;
}
#endif

} // namespace WebKit
