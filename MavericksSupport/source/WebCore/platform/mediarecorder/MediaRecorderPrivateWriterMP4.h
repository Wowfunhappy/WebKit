/*
 * Copyright (C) 2026 Jonathan. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(MEDIA_RECORDER)

#include "MediaRecorderPrivateWriter.h"
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class MediaRecorderPrivateWriterMP4Delegate;

// The MediaRecorder MP4 container writer: it takes the frames MediaRecorderPrivateEncoder has
// already compressed and packages them as a fragmented MP4, handing each fragment's bytes to the
// listener as they are produced.
class MediaRecorderPrivateWriterMP4 final : public MediaRecorderPrivateWriter {
    WTF_MAKE_TZONE_ALLOCATED(MediaRecorderPrivateWriterMP4);
public:
    static std::unique_ptr<MediaRecorderPrivateWriter> create(MediaRecorderPrivateWriterListener&);

    ~MediaRecorderPrivateWriterMP4();

private:
    explicit MediaRecorderPrivateWriterMP4(MediaRecorderPrivateWriterListener&);

    bool segmentsMustStartWithKeyframe() const final { return true; }
    std::optional<uint8_t> addAudioTrack(const AudioInfo&) final;
    std::optional<uint8_t> addVideoTrack(const VideoInfo&, const std::optional<CGAffineTransform>&) final;
    bool allTracksAdded() final;
    Result writeFrame(const MediaSamplesBlock&) final;
    void forceNewSegment(const MediaTime&) final;
    Ref<GenericPromise> close(Deque<UniqueRef<MediaSamplesBlock>>&&, const MediaTime&) final;
    // The track header carries no transform, so the capture source rotates the frames it hands
    // the encoder, as it does for the WebM container.
    bool shouldApplyVideoRotation() const final { return true; }

    const UniqueRef<MediaRecorderPrivateWriterMP4Delegate> m_delegate;
};

} // namespace WebCore

#endif // ENABLE(MEDIA_RECORDER)
