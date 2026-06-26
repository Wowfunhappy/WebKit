// MAVERICKS_BACKPORT: this file was stubbed empty during the backport (its upstream form is
// MediaUtilities.mm, which the backport excluded), which left WebCore::createVideoSampleBuffer()
// UNDEFINED. getUserMedia camera capture then crashed the WebContent process with a dyld
// "Symbol not found: WebCore::createVideoSampleBuffer(CVPixelBufferRef, CMTime)" the moment
// LocalSampleBufferDisplayLayer::enqueueVideoFrame() tried to wrap an incoming camera frame.
//
// The CoreMedia routines needed to build a CMSampleBuffer from a CVPixelBuffer ARE available on 10.9
// (CMVideoFormatDescriptionCreateForImageBuffer and CMSampleBufferCreateForImageBuffer are 10.7+), and
// WebCore already soft-links them through PAL, so reimplement createVideoSampleBuffer() here using those.
//
// (createAudioFormatDescription / createAudioSampleBuffer are part of the audio-capture path and are not
// reimplemented here; the video-only getUserMedia path does not reference them.)
#include "config.h"
#include "MediaUtilities.h"

#include <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

// MAVERICKS_BACKPORT: reimplemented for 10.9 (see file header) — the only routine the video getUserMedia path needs.
RetainPtr<CMSampleBufferRef> createVideoSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime sampleTime)
{
    if (!pixelBuffer)
        return nullptr;

    // MAVERICKS_BACKPORT: derive the format via CMVideoFormatDescriptionCreateForImageBuffer (10.7+), soft-linked through PAL.
    CMVideoFormatDescriptionRef rawFormatDescription = nullptr;
    if (PAL::CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &rawFormatDescription) != noErr || !rawFormatDescription)
        return nullptr;
    // MAVERICKS_BACKPORT: adopt the 10.9-soft-linked format description.
    auto formatDescription = adoptCF(rawFormatDescription);

    // MAVERICKS_BACKPORT: build the CMSampleBuffer via CMSampleBufferCreateForImageBuffer (10.7+), soft-linked through PAL.
    CMSampleTimingInfo timing = { PAL::kCMTimeInvalid, sampleTime, PAL::kCMTimeInvalid };
    CMSampleBufferRef rawSampleBuffer = nullptr;
    if (PAL::CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nullptr, nullptr, formatDescription.get(), &timing, &rawSampleBuffer) != noErr || !rawSampleBuffer)
        return nullptr;

    // MAVERICKS_BACKPORT: see file header — reimplemented createVideoSampleBuffer for 10.9.
    return adoptCF(rawSampleBuffer);
}

} // namespace WebCore
