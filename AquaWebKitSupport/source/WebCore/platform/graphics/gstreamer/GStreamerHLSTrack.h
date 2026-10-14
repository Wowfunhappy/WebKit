#pragma once

#include "AudioTrackPrivate.h"
#include "GRefPtrGStreamer.h"
#include "InbandTextTrackPrivate.h"
#include <optional>

namespace WebCore {

std::optional<String> hlsTrackLanguage(GstTagList*);
AudioTrackPrivate::Kind hlsAudioTrackKind(GstStream*, AudioTrackPrivate::Kind);
InbandTextTrackPrivate::Kind hlsTextTrackKind(GstStream*, InbandTextTrackPrivate::Kind);
bool hlsTextTrackIsDefault(GstStream*);

} // namespace WebCore
