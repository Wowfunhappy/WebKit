// MAVERICKS_BACKPORT: minimal RefCounted base replacing the upstream platform alias — the Mac/iOS PlaybackSessionInterface classes it would select aren't built on 10.9, so a standalone base type is provided instead.
// Minimal stub for 10.9
#pragma once
#include <wtf/RefCounted.h>
namespace WebCore {
// MAVERICKS_BACKPORT: standalone RefCounted base, since the platform PlaybackSessionInterface classes the upstream alias selects aren't built on 10.9.
class PlatformPlaybackSessionInterface : public RefCounted<PlatformPlaybackSessionInterface> {
public:
    virtual ~PlatformPlaybackSessionInterface() = default;
};
}
