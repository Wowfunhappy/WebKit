// 10.9 backport: minimal WebMediaStrategy implementation. The original WK2 file
// stages everything through GPU process; on this 10.9 backport GPU process is
// disabled, so we route createAudioDestination directly to AudioDestination::create
// like WebKitLegacy does. Without this, the polyfill-supplied empty vtable for
// WebMediaStrategy left createAudioDestination as a NULL function pointer, crashing
// at the call site in DefaultAudioDestinationNode::createDestination.
#include "config.h"
#include "WebMediaStrategy.h"

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

std::unique_ptr<WebCore::NowPlayingManager> WebMediaStrategy::createNowPlayingManager() const
{
    return makeUnique<WebCore::NowPlayingManager>();
}

bool WebMediaStrategy::hasThreadSafeMediaSourceSupport() const
{
    return false;
}

#if ENABLE(MEDIA_SOURCE)
void WebMediaStrategy::enableMockMediaSource()
{
}
#endif

#if PLATFORM(COCOA) && ENABLE(VIDEO)
void WebMediaStrategy::nativeImageFromVideoFrame(const WebCore::VideoFrame&, CompletionHandler<void(std::optional<RefPtr<WebCore::NativeImage>>&&)>&& completion)
{
    completion(std::nullopt);
}
#endif

#if ENABLE(VIDEO) && ENABLE(GPU_PROCESS)
RefPtr<WebCore::AudioVideoRenderer> WebMediaStrategy::createAudioVideoRenderer(LoggerHelper*, WebCore::HTMLMediaElementIdentifier, WebCore::MediaPlayerIdentifier) const
{
    return nullptr;
}

bool WebMediaStrategy::canDecodeExtendedType(WebCore::PlatformMediaDecodingType, const WebCore::ContentType&)
{
    return false;
}
#endif

} // namespace WebKit
