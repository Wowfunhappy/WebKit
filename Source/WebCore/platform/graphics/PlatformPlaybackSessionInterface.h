// Minimal stub for 10.9
#pragma once
#include <wtf/RefCounted.h>
namespace WebCore {
class PlatformPlaybackSessionInterface : public RefCounted<PlatformPlaybackSessionInterface> {
public:
    virtual ~PlatformPlaybackSessionInterface() = default;
};
}
