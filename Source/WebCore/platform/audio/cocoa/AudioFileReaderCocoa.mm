/*
 * MAVERICKS_BACKPORT: real in-memory Web Audio file decoder.
 *
 * Upstream WebKit decodes via AVAssetReader; that path was stubbed out on this
 * port ("non-critical feature"), which left createBusFromInMemoryAudioFile bound
 * to a polyfill return-0 stub that handed back a GARBAGE non-null RefPtr<AudioBus>.
 * decodeAudioData() then deref'd it → free() of an unallocated pointer → SIGABRT on
 * the Audio Decoder thread (frequent crash on any page that uses Web Audio, e.g.
 * scritch.dev/play). This restores a working decoder using the classic
 * AudioFileOpenWithCallbacks + ExtAudioFile approach, which is fully available on
 * 10.9 and decodes in-memory compressed/PCM audio to a float AudioBus (with sample
 * rate conversion and optional mix-to-mono), exactly what Web Audio needs.
 */

#import "config.h"

#if ENABLE(WEB_AUDIO)
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// #import "AudioFileReaderCocoa.h"
// (end MAVERICKS_BACKPORT restored block)

#import "AudioBus.h"
// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
#import "AudioChannel.h"
#import "AudioFileReader.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#import "AudioSampleDataSource.h"
#import "AudioTrackPrivateWebM.h"
#import "CMUtilities.h"
#import "FloatConversion.h"
#import "InbandTextTrackPrivate.h"
#import "Logging.h"
#import "MIMESniffer.h"
#import "MediaSampleAVFObjC.h"
#import "SharedBuffer.h"
#import "VideoTrackPrivate.h"
#import "WebMAudioUtilitiesCocoa.h"
#import <AVFoundation/AVAsset.h>
#import <AVFoundation/AVAssetReader.h>
#import <AVFoundation/AVAssetReaderOutput.h>
#import <AVFoundation/AVAssetTrack.h>
#import <AudioToolbox/AudioConverter.h>
#import <CoreFoundation/CoreFoundation.h>
#import <SourceBufferParserWebM.h>
#import <limits>
#import <pal/cf/CoreAudioExtras.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/Function.h>
#import <wtf/NativePromise.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/Scope.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/Vector.h>
#import <wtf/cf/TypeCastsCF.h>
#import <wtf/darwin/DispatchExtras.h>

#import <pal/cf/AudioToolboxSoftLink.h>
#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

// Delegate class for AVAssetResourceLoader to provide data from memory
@interface WebCoreAudioFileReaderLoaderDelegate : NSObject<AVAssetResourceLoaderDelegate> {
    std::span<const uint8_t> _data;
    String _mimeType;
}
- (instancetype)initWithData:(std::span<const uint8_t>)data mimeType:(const String&)mimeType;
- (void)close;
@end

@implementation WebCoreAudioFileReaderLoaderDelegate

- (instancetype)initWithData:(std::span<const uint8_t>)data mimeType:(const String&)mimeType
{
    if (!(self = [super init]))
        return nil;
    _data = data;
    _mimeType = mimeType;
    return self;
}

- (void)close
{
    _data = { };
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{
    UNUSED_PARAM(resourceLoader);
MAVERICKS_BACKPORT */

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header); uses AudioToolbox (10.9-available).
#import <AudioToolbox/AudioToolbox.h>
#import <algorithm>
#import <cmath>
#import <wtf/FastMalloc.h>

namespace WebCore {

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
namespace {

struct MemoryAudioSource {
    const uint8_t* data;
    size_t size;
};

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
OSStatus memoryReadProc(void* clientData, SInt64 position, UInt32 requestCount, void* buffer, UInt32* actualCount)
{
    auto& source = *static_cast<MemoryAudioSource*>(clientData);
    if (position < 0 || static_cast<size_t>(position) > source.size) {
        *actualCount = 0;
        return kAudioFileInvalidPacketOffsetError;
    }
    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    size_t available = source.size - static_cast<size_t>(position);
    size_t toCopy = std::min<size_t>(requestCount, available);
    if (toCopy)
        memcpy(buffer, source.data + position, toCopy);
    *actualCount = static_cast<UInt32>(toCopy);
    return noErr;
}

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
SInt64 memoryGetSizeProc(void* clientData)
{
    return static_cast<SInt64>(static_cast<MemoryAudioSource*>(clientData)->size);
}

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
} // anonymous namespace

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
RefPtr<AudioBus> createBusFromInMemoryAudioFile(std::span<const uint8_t> data, bool mixToMono, float sampleRate)
{
    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (data.empty())
        return nullptr;
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     }
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    MemoryAudioSource source { data.data(), data.size() };

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    AudioFileID audioFileID = nullptr;
    OSStatus status = AudioFileOpenWithCallbacks(&source, memoryReadProc, nullptr, memoryGetSizeProc, nullptr, 0, &audioFileID);
    if (status != noErr || !audioFileID)
        return nullptr;
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     parser->flushPendingAudioSamples();
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    ExtAudioFileRef extAudioFile = nullptr;
    status = ExtAudioFileWrapAudioFileID(audioFileID, false, &extAudioFile);
    if (status != noErr || !extAudioFile) {
        AudioFileClose(audioFileID);
        return nullptr;
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

    return makeUnique<AudioFileReaderData>(AudioFileReaderData {
        .trimStart = track->codecDelay(),
        .trimEnd = track->discardPadding(),
        .samples = WTF::move(samples),
        .numberOfFrames = *frames
    });
}
#endif

struct PassthroughUserData {
    const UInt32 m_channels;
    std::span<const uint8_t> m_data;
    const bool m_eos;
    const Vector<AudioStreamPacketDescription>& m_packets;
    UInt32 m_index;
    AudioStreamPacketDescription m_packet;
};

// Error value we pass through the decoder to signal that nothing
// has gone wrong during decoding and we're done processing the packet.
const uint32_t kNoMoreDataErr = 'MOAR';

static OSStatus passthroughInputDataCallback(AudioConverterRef, UInt32* numDataPackets, AudioBufferList* data, AudioStreamPacketDescription** packetDesc, void* inUserData)
{
    ASSERT(numDataPackets && data && inUserData);
    if (!numDataPackets || !data || !inUserData)
        return kAudioConverterErr_UnspecifiedError;

    auto* userData = static_cast<PassthroughUserData*>(inUserData);
    if (userData->m_index == userData->m_packets.size()) {
        *numDataPackets = 0;
        return userData->m_eos ? noErr : kNoMoreDataErr;
    }

    if (userData->m_index >= userData->m_packets.size()) {
        *numDataPackets = 0;
        return kAudioConverterErr_RequiresPacketDescriptionsError;
    }

    if (packetDesc) {
        userData->m_packet = userData->m_packets[userData->m_index];
        userData->m_packet.mStartOffset = 0;
        *packetDesc = &userData->m_packet;
    }

    auto& firstBuffer = span(*data)[0];
    firstBuffer.mNumberChannels = userData->m_channels;
    firstBuffer.mDataByteSize = userData->m_packets[userData->m_index].mDataByteSize;

    firstBuffer.mData = const_cast<uint8_t*>(userData->m_data.subspan(userData->m_packets[userData->m_index].mStartOffset).data());

    // Sanity check
    if (std::to_address(span<uint8_t>(firstBuffer).end()) > std::to_address(userData->m_data.end())) {
        RELEASE_LOG_FAULT(WebAudio, "Nonsensical data structure, aborting");
        return kAudioConverterErr_UnspecifiedError;
MAVERICKS_BACKPORT */
    }

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    auto cleanup = [&] {
        ExtAudioFileDispose(extAudioFile);
        AudioFileClose(audioFileID);
    };
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    setChannelLayoutIfNeeded();

    AudioBufferListHolder decodedBufferList(inFormat.mChannelsPerFrame);
    if (!decodedBufferList) {
        RELEASE_LOG_FAULT(WebAudio, "Unable to create decoder");
        return { };
    }

    // Configure AudioConverter to trim initial frames.
    auto framesTrimmedAtStart = m_readerData->trimStart.value_or(MediaTime::zeroTime()).toTimeScale(inFormat.mSampleRate).timeValue();
    auto framesTrimmedAtEnd = m_readerData->trimEnd.value_or(MediaTime::zeroTime()).toTimeScale(inFormat.mSampleRate).timeValue();

    if (framesTrimmedAtStart < 0 || framesTrimmedAtStart > std::numeric_limits<int32_t>::max() || framesTrimmedAtEnd < 0 || framesTrimmedAtEnd > std::numeric_limits<int32_t>::max())
        return { };
    auto totalFramesTrimmed = WTF::checkedSum<uint32_t>(framesTrimmedAtStart, framesTrimmedAtEnd);
    if (totalFramesTrimmed.hasOverflowed())
        return { };
    if (m_readerData->numberOfFrames < totalFramesTrimmed.value())
        return { };
    size_t initialNumberOfFramesAfterTrim = m_readerData->numberOfFrames - totalFramesTrimmed.value();
    auto convertedNumberOfFramesAfterTrim = std::round<size_t>(initialNumberOfFramesAfterTrim * (outFormat.mSampleRate / inFormat.mSampleRate));

    AudioConverterPrimeInfo primeInfo = { static_cast<UInt32>(framesTrimmedAtStart), static_cast<UInt32>(framesTrimmedAtEnd) };
    PAL::AudioConverterSetProperty(converter, kAudioConverterPrimeInfo, sizeof(primeInfo), &primeInfo);

    size_t totalDecodedFrames = 0;
    OSStatus status;
    for (size_t i = 0; i < m_readerData->samples.size(); i++) {
        auto& sample = m_readerData->samples[i];
        RetainPtr sampleBuffer = sample->sampleBuffer();
        RetainPtr rawBuffer = PAL::CMSampleBufferGetDataBuffer(sampleBuffer.get());
        RetainPtr<CMBlockBufferRef> buffer = rawBuffer.get();
        if (!PAL::CMBlockBufferIsRangeContiguous(rawBuffer.get(), 0, 0)) {
            CMBlockBufferRef contiguousBuffer = nullptr;
            if (PAL::CMBlockBufferCreateContiguous(nullptr, rawBuffer.get(), nullptr, nullptr, 0, 0, 0, &contiguousBuffer) != kCMBlockBufferNoErr) {
                RELEASE_LOG_FAULT(WebAudio, "failed to create contiguous block buffer");
                return { };
            }
            buffer = adoptCF(contiguousBuffer);
        }

        auto srcData = PAL::CMBlockBufferGetDataSpan(buffer.get());
        if (!srcData.data()) {
            RELEASE_LOG_FAULT(WebAudio, "Unable to retrieve data");
            return { };
        }
MAVERICKS_BACKPORT */

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    AudioStreamBasicDescription fileFormat { };
    UInt32 propertySize = sizeof(fileFormat);
    status = ExtAudioFileGetProperty(extAudioFile, kExtAudioFileProperty_FileDataFormat, &propertySize, &fileFormat);
    if (status != noErr || !fileFormat.mChannelsPerFrame || fileFormat.mSampleRate <= 0) {
        cleanup();
        return nullptr;
    }

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    unsigned numberOfChannels = fileFormat.mChannelsPerFrame;
    double fileSampleRate = fileFormat.mSampleRate;
    double targetSampleRate = sampleRate > 0 ? sampleRate : fileSampleRate;

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    // Deinterleaved native-endian Float32 at the target sample rate (ExtAudioFile does the SRC).
    AudioStreamBasicDescription clientFormat { };
    clientFormat.mFormatID = kAudioFormatLinearPCM;
    clientFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    clientFormat.mSampleRate = targetSampleRate;
    clientFormat.mChannelsPerFrame = numberOfChannels;
    clientFormat.mBitsPerChannel = 8 * sizeof(Float32);
    clientFormat.mFramesPerPacket = 1;
    clientFormat.mBytesPerFrame = sizeof(Float32);
    clientFormat.mBytesPerPacket = sizeof(Float32);

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    status = ExtAudioFileSetProperty(extAudioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
    if (status != noErr) {
        cleanup();
        return nullptr;
    }

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    SInt64 fileFrameCount = 0;
    propertySize = sizeof(fileFrameCount);
    status = ExtAudioFileGetProperty(extAudioFile, kExtAudioFileProperty_FileLengthFrames, &propertySize, &fileFrameCount);
    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (status != noErr || fileFrameCount <= 0) {
        cleanup();
        return nullptr;
    } // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    // Frame count after sample-rate conversion (round up + small margin so we never truncate).
    double ratio = targetSampleRate / fileSampleRate;
    size_t numberOfFrames = static_cast<size_t>(std::ceil(static_cast<double>(fileFrameCount) * ratio)) + 1;
    if (!numberOfFrames) {
        cleanup();
        return nullptr;
    }

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    auto audioBus = AudioBus::create(numberOfChannels, numberOfFrames);
    audioBus->setSampleRate(targetSampleRate);

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    // An AudioBufferList whose per-channel buffers point straight at the AudioBus channel storage.
    size_t bufferListSize = offsetof(AudioBufferList, mBuffers) + numberOfChannels * sizeof(::AudioBuffer);
    auto* bufferList = static_cast<AudioBufferList*>(fastMalloc(bufferListSize));
    bufferList->mNumberBuffers = numberOfChannels;

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    size_t framesRead = 0;
    while (framesRead < numberOfFrames) {
        UInt32 framesToRead = static_cast<UInt32>(numberOfFrames - framesRead);
        for (unsigned i = 0; i < numberOfChannels; ++i) {
            bufferList->mBuffers[i].mNumberChannels = 1;
            bufferList->mBuffers[i].mDataByteSize = framesToRead * sizeof(Float32);
            bufferList->mBuffers[i].mData = audioBus->channel(i)->mutableData() + framesRead;
        }

        // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
        UInt32 frames = framesToRead;
        status = ExtAudioFileRead(extAudioFile, &frames, bufferList);
        if (status != noErr)
            break;
        if (!frames)
            break; // EOF.
        framesRead += frames;
    }
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    return std::min<size_t>(totalDecodedFrames, convertedNumberOfFramesAfterTrim);
}

// Helper struct for AVF passthrough callback
struct AVFPassthroughUserData {
    const UInt32 m_channels;
    std::span<const uint8_t> m_data;
    const bool m_eos;
    const Vector<AudioStreamPacketDescription>& m_packets;
    UInt32 m_index;
    AudioStreamPacketDescription m_packet;
};

std::optional<AudioStreamBasicDescription> AudioFileReader::fileDataFormat() const
{
    if (!m_readerData || m_readerData->samples.isEmpty())
        return { };

    RetainPtr formatDescription = PAL::CMSampleBufferGetFormatDescription(RetainPtr { m_readerData->samples[0]->sampleBuffer() }.get());
    if (!formatDescription)
        return { };

    const AudioStreamBasicDescription* const asbd = PAL::CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription.get());
    return *asbd;
}

AudioStreamBasicDescription AudioFileReader::clientDataFormat(const AudioStreamBasicDescription& inFormat, float sampleRate) const
{
    // Make client format same number of channels as file format, but tweak a few things.
    // Client format will be linear PCM (canonical), and potentially change sample-rate.
    AudioStreamBasicDescription outFormat = inFormat;

    const int bytesPerFloat = sizeof(Float32);
    const int bitsPerByte = 8;
    outFormat.mFormatID = kAudioFormatLinearPCM;
    outFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    outFormat.mBytesPerPacket = outFormat.mBytesPerFrame = bytesPerFloat;
    outFormat.mFramesPerPacket = 1;
    outFormat.mBitsPerChannel = bitsPerByte * bytesPerFloat;

    if (sampleRate)
        outFormat.mSampleRate = sampleRate;

    return outFormat;
}

RefPtr<AudioBus> AudioFileReader::createBus(float sampleRate, bool mixToMono)
{
    auto inFormat = fileDataFormat();
    if (!inFormat)
        return nullptr;
MAVERICKS_BACKPORT */

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    fastFree(bufferList);
    cleanup();

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (!framesRead)
        return nullptr;
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     numberOfFrames = *decodedFrames;
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: the bus was over-allocated (ceil(frames*ratio) + 1) so the sample-rate conversion
    // never truncates; trim it to the frames actually decoded so decodeAudioData reports the exact length
    // and carries no trailing silence (else a 176400-frame WAV decoded to length 176401 with a silent frame).
    if (framesRead < numberOfFrames)
        audioBus->setLength(framesRead);

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (mixToMono && numberOfChannels > 1)
        return AudioBus::createByMixingToMono(audioBus.get());

    return audioBus;
}

} // namespace WebCore -- MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
#endif // ENABLE(WEB_AUDIO)
