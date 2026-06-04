// Stubbed for macOS 10.9 backport - uses CoreMedia PAL soft-link APIs not available
#include "config.h"
#include "WebAudioBufferList.h"

#include <CoreAudio/CoreAudioTypes.h>

namespace WebCore {

// 10.9 backport: the rest of WebAudioBufferList is stubbed (its construction path uses CoreMedia
// soft-link APIs unavailable on 10.9), but setSampleCount is referenced by
// SpeechRecognitionRemoteRealtimeMediaSource and must resolve for the WebKit framework to link.
// Provide a minimal, self-contained version (no computeBufferSizes/initializeList/m_flatBuffer deps,
// which are stubbed) that simply clamps each buffer's byte size to the requested sample count.
void WebAudioBufferList::setSampleCount(size_t sampleCount)
{
    if (!sampleCount || m_sampleCount == sampleCount)
        return;
    m_sampleCount = sampleCount;
    if (AudioBufferList* bufferList = list()) {
        for (uint32_t i = 0; i < bufferList->mNumberBuffers; ++i)
            bufferList->mBuffers[i].mDataByteSize = static_cast<UInt32>(sampleCount * m_bytesPerFrame);
    }
}

// 10.9 backport: also referenced (besides setSampleCount) and otherwise undefined because the rest of
// this file is stubbed. Returns a range over the live AudioBufferList's buffers (empty if unset).
IteratorRange<AudioBuffer*> WebAudioBufferList::buffers() const
{
    AudioBufferList* bufferList = list();
    if (!bufferList || !bufferList->mNumberBuffers)
        return { nullptr, nullptr };
    return { &bufferList->mBuffers[0], &bufferList->mBuffers[0] + bufferList->mNumberBuffers };
}

} // namespace WebCore
