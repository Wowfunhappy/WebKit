/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "VideoEncoder.h"

#if ENABLE(VIDEO)

#if USE(LIBWEBRTC) && PLATFORM(COCOA)
#include "LibWebRTCVPXVideoEncoder.h"
#endif

#if USE(GSTREAMER)
#include "VideoEncoderGStreamer.h"
#endif

namespace WebCore {

VideoEncoder::CreatorFunction VideoEncoder::s_customCreator = nullptr;

void VideoEncoder::setCreatorCallback(CreatorFunction&& function)
{
    s_customCreator = WTF::move(function);
}

Ref<VideoEncoder::CreatePromise> VideoEncoder::create(const String& codecName, const Config& config, DescriptionCallback&& descriptionCallback, OutputCallback&& outputCallback)
{
    CreatePromise::Producer producer;
    Ref promise = producer.promise();
    CreateCallback callback = [producer = WTF::move(producer)] (auto&& result) mutable {
        producer.settle(WTF::move(result));
    };

    if (s_customCreator) {
        s_customCreator(codecName, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
        return promise;
    }
    createLocalEncoder(codecName, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
    return promise;
}

void VideoEncoder::createLocalEncoder(const String& codecName, const Config& config, CreateCallback&& callback, DescriptionCallback&& descriptionCallback, OutputCallback&& outputCallback)
{
#if USE(LIBWEBRTC) && PLATFORM(COCOA)
    if (codecName == "vp8"_s) {
        LibWebRTCVPXVideoEncoder::create(LibWebRTCVPXVideoEncoder::Type::VP8, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
        return;
    }
    if (codecName.startsWith("vp09.00"_s)) {
        LibWebRTCVPXVideoEncoder::create(LibWebRTCVPXVideoEncoder::Type::VP9, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
        return;
    }
    if (codecName.startsWith("vp09.02"_s)) {
        LibWebRTCVPXVideoEncoder::create(LibWebRTCVPXVideoEncoder::Type::VP9_P2, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
        return;
    }
#if ENABLE(AV1)
    if (codecName.startsWith("av01."_s)) {
        LibWebRTCVPXVideoEncoder::create(LibWebRTCVPXVideoEncoder::Type::AV1, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
        return;
    }
#endif
#endif // MAVERICKS_BACKPORT: closes the USE(LIBWEBRTC) && PLATFORM(COCOA) block, which upstream
// continues as `#elif USE(GSTREAMER)`. That either/or does not describe this port: it is
// PLATFORM(COCOA) with USE(LIBWEBRTC), and GStreamer is its media engine. Ending the block here lets
// a codec the arm above does not claim reach the GStreamer encoder below, which is also the only
// encoder WebKitLegacy can reach at all -- there is no WebProcess there, so no RemoteVideoCodecFactory
// installs a creator callback and every WebCodecs request lands in this function.

#if USE(GSTREAMER)
    GStreamerVideoEncoder::create(codecName, config, WTF::move(callback), WTF::move(descriptionCallback), WTF::move(outputCallback));
    return;
#endif

#if !(USE(LIBWEBRTC) && PLATFORM(COCOA)) && !USE(GSTREAMER) // MAVERICKS_BACKPORT: upstream spells this arm `#else`.
    UNUSED_PARAM(codecName);
    UNUSED_PARAM(config);
    UNUSED_PARAM(descriptionCallback);
    UNUSED_PARAM(outputCallback);
#endif

    callback(makeUnexpected("Not supported"_s));
}

}

#endif // ENABLE(VIDEO)
