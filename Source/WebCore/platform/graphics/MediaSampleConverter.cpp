// MAVERICKS_BACKPORT: gutted to an empty TU on 10.9 — MediaSampleConverter's PAL CoreMedia soft-link path (CMSampleBufferGetFormatDescription) is unusable on this build; nothing here links the missing implementation in.
// Stubbed for macOS 10.9 - CoreMedia PAL soft-link API mismatch
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "MediaSampleConverter.h"

#include <WebCore/MediaSample.h>
#include <WebCore/MediaSamplesBlock.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(COCOA)
#include <CoreMedia/CMFormatDescription.h>

#include <pal/cf/CoreMediaSoftLink.h>
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(MediaSampleConverter);

MediaSampleConverter::MediaSampleConverter() = default;
MediaSampleConverter::~MediaSampleConverter() = default;

static bool hasSameInitSegment(const MediaSample& sampleA, const MediaSample& sampleB)
{
#if PLATFORM(COCOA)
    RetainPtr cmSampleA = sampleA.platformSample().cmSampleBuffer();
    RetainPtr cmSampleB = sampleB.platformSample().cmSampleBuffer();
    RetainPtr descriptionA = PAL::CMSampleBufferGetFormatDescription(cmSampleA.get());
    RetainPtr descriptionB = PAL::CMSampleBufferGetFormatDescription(cmSampleB.get());
    return descriptionA == descriptionB;
#else
    UNUSED_PARAM(sampleA);
    UNUSED_PARAM(sampleB);
    return false;
#endif
}

UniqueRef<MediaSamplesBlock> MediaSampleConverter::convert(const MediaSample& sample, SetTrackInfo setTrackInfo)
{
    bool canReuseLastTrackInfo = m_lastSample && hasSameInitSegment(sample, Ref { *m_lastSample });
    auto block = MediaSamplesBlock::fromMediaSample(sample, canReuseLastTrackInfo ? m_lastTrackInfo.get() : nullptr);
    if (!canReuseLastTrackInfo) {
        m_lastTrackInfo = block->info();
        m_lastSample = &sample;
    }
    if (setTrackInfo == SetTrackInfo::No)
        block->setInfo(nullptr);
    return block;
}

RefPtr<MediaSample> MediaSampleConverter::convert(MediaSamplesBlock&& block)
{
    ASSERT(m_lastTrackInfo || block.info());
    if (!block.info())
        block.setInfo(m_lastTrackInfo.get());
    RefPtr sample = block.toMediaSample(m_lastSample.get());
    if (!m_lastSample)
        m_lastSample = sample;
    return sample;
}

bool MediaSampleConverter::hasFormatChanged(const MediaSample& sample)
{
    if (RefPtr lastSample = m_lastSample)
        return !hasSameInitSegment(*lastSample, sample);
    return true;
}

RefPtr<const TrackInfo> MediaSampleConverter::currentTrackInfo() const
{
    return m_lastTrackInfo;
}

void MediaSampleConverter::setTrackInfo(Ref<const TrackInfo>&& trackInfo)
{
    if (m_lastTrackInfo && trackInfo.get() != *m_lastTrackInfo)
        m_lastSample = nullptr;
    m_lastTrackInfo = WTF::move(trackInfo);
}

}
MAVERICKS_BACKPORT */
