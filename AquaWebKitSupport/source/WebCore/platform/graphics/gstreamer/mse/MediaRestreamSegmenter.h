#pragma once

#include <WebCore/SharedBuffer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Vector.h>
#include <memory>
#include <map>
#include "GStreamerCommon.h"

namespace WebCore {
using RestreamCounters = std::map<unsigned, uint64_t>;
struct RestreamTransportInfo {
    RestreamCounters packets;
    std::map<unsigned, unsigned> bases;
    std::map<unsigned, Vector<uint8_t>> tables;
    bool operator==(const RestreamTransportInfo&) const = default;
};
class MediaRestreamSegmenter {
public:
    static std::optional<RestreamTransportInfo> transportInfo(const SharedBuffer&);
    static Ref<SharedBuffer> withContinuity(const SharedBuffer&, const RestreamCounters&);
};
}
