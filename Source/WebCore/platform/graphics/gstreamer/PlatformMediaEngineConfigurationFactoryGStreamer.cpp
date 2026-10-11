/*
 * Copyright (C) 2019 Igalia S.L.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "PlatformMediaEngineConfigurationFactoryGStreamer.h"

#if USE(GSTREAMER)

// AQUAWEBKIT: the VP9 decoder setting is answered from the configuration's codec list.
#include "ContentType.h"
#include "GStreamerRegistryScanner.h"
#include "PlatformMediaCapabilitiesDecodingInfo.h"
#include "PlatformMediaCapabilitiesEncodingInfo.h"
#include "PlatformMediaDecodingConfiguration.h"
#include "PlatformMediaEncodingConfiguration.h"
#include <wtf/Function.h>

#if ENABLE(MEDIA_SOURCE)
#include "GStreamerRegistryScannerMSE.h"
#endif

namespace WebCore {

void createMediaPlayerDecodingConfigurationGStreamer(PlatformMediaDecodingConfiguration&& configuration, Function<void(PlatformMediaCapabilitiesDecodingInfo&&)>&& callback)
{
    // AQUAWEBKIT: a configuration naming VP9 is unsupported while the VP9 decoder setting is
    // off, the rule PlatformMediaEngineConfigurationFactoryCocoa.cpp applies to the same configuration.
    if (!configuration.canExposeVP9 && configuration.video) {
        auto codecs = ContentType(configuration.video->contentType).codecs();
        // The codec spellings GStreamerRegistryScanner registers for video/x-vp9.
        if (codecs.containsIf([](auto& codec) { return codec.startsWith("vp09"_s) || codec.startsWith("vp9"_s) || codec.startsWith("x-vp9"_s); })) {
            callback({{ }, WTF::move(configuration)});
            return;
        }
    }

    bool isMediaSource = configuration.type == PlatformMediaDecodingType::MediaSource;
#if ENABLE(MEDIA_SOURCE)
    auto& scanner = isMediaSource ? GStreamerRegistryScannerMSE::singleton() : GStreamerRegistryScanner::singleton();
#else
    if (isMediaSource) {
        callback({{ }, WTF::move(configuration)});
        return;
    }
    auto& scanner = GStreamerRegistryScanner::singleton();
#endif
    auto lookupResult = scanner.isDecodingSupported(configuration);
    PlatformMediaCapabilitiesDecodingInfo info;
    info.supported = lookupResult.isSupported;
    info.powerEfficient = lookupResult.isUsingHardware;
    info.smooth = lookupResult.isSupported;

    // AQUAWEBKIT: AV1 is reported not smooth, at the maintainer's direction, so a site choosing
    // between codecs prefers a lighter one on the hardware 10.9 runs on.
    if (configuration.video) {
        auto codecs = ContentType(configuration.video->contentType).codecs();
        // The codec spellings GStreamerRegistryScanner registers for video/x-av1.
        if (codecs.containsIf([](auto& codec) { return codec.startsWith("av01"_s) || codec == "av1"_s || codec == "x-av1"_s; }))
            info.smooth = false;
    }

    if (configuration.audio && configuration.audio->spatialRendering.value_or(false)) {
        auto channelCount = configuration.audio->channels.toDouble();
        info.supported &= channelCount > 2;
    }

    info.configuration = WTF::move(configuration);
    callback(WTF::move(info));
}

void createMediaPlayerEncodingConfigurationGStreamer(PlatformMediaEncodingConfiguration&& configuration, Function<void(PlatformMediaCapabilitiesEncodingInfo&&)>&& callback)
{
    auto& scanner = GStreamerRegistryScanner::singleton();
    auto lookupResult = scanner.isEncodingSupported(configuration);
    PlatformMediaCapabilitiesEncodingInfo info;
    info.supported = lookupResult.isSupported;
    info.powerEfficient = lookupResult.isUsingHardware;
    info.configuration = WTF::move(configuration);
    info.smooth = lookupResult.isSupported;

    callback(WTF::move(info));
}

} // namespace WebCore

#endif // USE(GSTREAMER)
