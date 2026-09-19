#pragma once

#include "AudioTrackPrivate.h"
#include "GRefPtrGStreamer.h"
#include "InbandTextTrackPrivate.h"
#include <optional>

namespace WebCore {

std::optional<String> hlsTrackLanguage(GstTagList*);
GRefPtr<GstStream> hlsDescribingStream(GRefPtr<GstStream>, const GRefPtr<GstPad>&);
GRefPtr<GstTagList> hlsTrackTags(const GRefPtr<GstPad>&);
AudioTrackPrivate::Kind hlsAudioTrackKind(GRefPtr<GstStream>, const GRefPtr<GstPad>&, AudioTrackPrivate::Kind);
InbandTextTrackPrivate::Kind hlsTextTrackKind(GRefPtr<GstStream>, const GRefPtr<GstPad>&, InbandTextTrackPrivate::Kind);
bool hlsTextTrackIsDefault(const GRefPtr<GstPad>&);

} // namespace WebCore
