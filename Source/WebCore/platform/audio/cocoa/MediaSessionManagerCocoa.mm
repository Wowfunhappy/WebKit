// 10.9 backport: minimal PlatformMediaSessionManager::create on Cocoa.
// The full upstream MediaSessionManagerCocoa class hooks AVFoundation/CoreAudio
// notifications that don't exist on 10.9. We provide just the factory so
// HTMLMediaElement::initializeMediaSession can succeed without crashing.
// <video>/<audio> elements are inert (no actual playback) but at least the
// page doesn't crash on auto-play sites.
#include "config.h"
#include "PlatformMediaSessionManager.h"

namespace WebCore {

#if PLATFORM(COCOA)
RefPtr<PlatformMediaSessionManager> PlatformMediaSessionManager::create(PageIdentifier pageIdentifier)
{
    return adoptRef(new PlatformMediaSessionManager(pageIdentifier));
}
#endif

}
