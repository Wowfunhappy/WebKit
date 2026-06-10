// 10.9 backport: the full AudioSampleDataSource (the ring-buffer + AudioConverter resampling DSP that
// carries captured-microphone samples) is NOT ported — this .mm is stubbed, so audio getUserMedia capture
// is not yet functional on 10.9 (only video capture is). However `setLogger()` IS referenced by the audio
// capture-source setup, and leaving it undefined caused a dyld "Symbol not found: ...setLogger..." crash
// the moment getUserMedia({audio:true}) was attempted. Define it so the capture path doesn't dyld-crash;
// making audio actually capture still requires porting the rest of this class.
#include "config.h"
#include "AudioSampleDataSource.h"

namespace WebCore {

void AudioSampleDataSource::setLogger(Ref<const Logger>&& logger, uint64_t logIdentifier)
{
    m_logger = WTF::move(logger);
    m_logIdentifier = logIdentifier;
}

} // namespace WebCore
