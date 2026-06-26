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

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
#import "AudioBus.h"
#import "AudioChannel.h"
#import "AudioFileReader.h"

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

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    MemoryAudioSource source { data.data(), data.size() };

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    AudioFileID audioFileID = nullptr;
    OSStatus status = AudioFileOpenWithCallbacks(&source, memoryReadProc, nullptr, memoryGetSizeProc, nullptr, 0, &audioFileID);
    if (status != noErr || !audioFileID)
        return nullptr;

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    ExtAudioFileRef extAudioFile = nullptr;
    status = ExtAudioFileWrapAudioFileID(audioFileID, false, &extAudioFile);
    if (status != noErr || !extAudioFile) {
        AudioFileClose(audioFileID);
        return nullptr;
    }

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    auto cleanup = [&] {
        ExtAudioFileDispose(extAudioFile);
        AudioFileClose(audioFileID);
    };

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

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    fastFree(bufferList);
    cleanup();

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (!framesRead)
        return nullptr;

    // MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
    if (mixToMono && numberOfChannels > 1)
        return AudioBus::createByMixingToMono(audioBus.get());

    return audioBus;
}

} // namespace WebCore -- MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).

// MAVERICKS_BACKPORT: rewritten in-memory Web Audio decoder (see file header).
#endif // ENABLE(WEB_AUDIO)
