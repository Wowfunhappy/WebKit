// The constant-bytes-per-packet input shim in polyfills/c/AudioToolboxOpus.c: an input callback that
// reports one packet for a buffer holding many is taken at its byte count, an LPCM source is asked for
// no packet descriptions, and every other caller is untouched. Four arms: a conforming CBR caller
// decodes identically with the shim in the path, a VBR caller reaches its own callback unaltered, the
// under-reporting LPCM caller -- the shape AudioFileReaderCocoa's passthroughInputDataCallback has --
// succeeds where 10.9 answers 'insz', and a caller that keys its packet count off the description
// pointer -- the shape AudioSampleBufferConverter::provideSourceDataNumOutputPackets has, which
// MediaRecorder's AAC encoding runs through -- feeds the encoder every frame it was handed.

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(const char *what, long got, long want)
{
    int ok = got == want;
    printf("  %-56s %-12ld %s\n", what, got, ok ? "ok" : "FAIL");
    if (!ok) {
        printf("  %-56s expected %ld\n", "", want);
        ++failures;
    }
}

enum { kFrames = 4096, kBytesPerFrame = 3 };

typedef struct {
    const unsigned char *data;
    UInt32 bytes;
    UInt32 packetsToReport;   // 1 = the under-reporting shape; kFrames = a conforming caller
    int served;
    int callbacks;
} Source;

static OSStatus feed(AudioConverterRef converter, UInt32 *packets, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *userData)
{
    Source *source = (Source *)userData;
    ++source->callbacks;
    if (source->served) {
        *packets = 0;
        return noErr;
    }
    if (descriptions)
        *descriptions = NULL;
    data->mBuffers[0].mNumberChannels = 1;
    data->mBuffers[0].mDataByteSize = source->bytes;
    data->mBuffers[0].mData = (void *)source->data;
    *packets = source->packetsToReport;
    source->served = 1;
    return noErr;
}

static AudioStreamBasicDescription lpcm24(void)
{
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = 44100;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 24;
    return format;
}

static AudioStreamBasicDescription canonicalFloat(AudioStreamBasicDescription source)
{
    AudioStreamBasicDescription format = source;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBitsPerChannel = 32;
    return format;
}

// Decodes through the converter and answers the frame count, or -1 on an error status.
static long decode(AudioStreamBasicDescription in, Source *source, float *out, UInt32 capacityFrames)
{
    AudioConverterRef converter = NULL;
    AudioStreamBasicDescription outFormat = canonicalFloat(in);
    if (AudioConverterNew(&in, &outFormat, &converter) != noErr)
        return -2;

    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = capacityFrames * sizeof(float);
    list.mBuffers[0].mData = out;

    UInt32 frames = capacityFrames;
    OSStatus status = AudioConverterFillComplexBuffer(converter, feed, source, &frames, &list, NULL);
    AudioConverterDispose(converter);
    if (status != noErr)
        return -1;
    return frames;
}

// AudioSampleBufferConverter::provideSourceDataNumOutputPackets answers a non-NULL description
// pointer with its packet-description count, which is empty for raw PCM. 10.9 passes that pointer
// where modern AudioToolbox passes NULL, so without the shim the count is zero however many frames
// the buffer holds and the encoder behind it is fed nothing.
static OSStatus feedKeyedOnDescriptionPointer(AudioConverterRef converter, UInt32 *packets,
    AudioBufferList *data, AudioStreamPacketDescription **descriptions, void *userData)
{
    (void)converter;
    Source *source = (Source *)userData;
    ++source->callbacks;
    if (descriptions)
        *descriptions = NULL;
    if (source->served) {
        *packets = 0;
        return noErr;
    }
    data->mBuffers[0].mNumberChannels = 1;
    data->mBuffers[0].mDataByteSize = source->bytes;
    data->mBuffers[0].mData = (void *)source->data;
    source->served = 1;
    *packets = descriptions ? 0 : source->bytes / (UInt32)sizeof(float);
    return noErr;
}

// Encodes float LPCM to AAC and answers the number of packets the encoder produced, or -1 on error.
static long encodeToAAC(Source *source)
{
    AudioStreamBasicDescription in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.mSampleRate = 48000;
    in.mFormatID = kAudioFormatLinearPCM;
    in.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    in.mBytesPerPacket = in.mBytesPerFrame = sizeof(float);
    in.mFramesPerPacket = 1;
    in.mChannelsPerFrame = 1;
    in.mBitsPerChannel = 32;
    out.mSampleRate = 48000;
    out.mFormatID = kAudioFormatMPEG4AAC;
    out.mChannelsPerFrame = 1;

    AudioConverterRef converter = NULL;
    if (AudioConverterNew(&in, &out, &converter) != noErr)
        return -1;

    UInt32 maxPacket = 0, size = sizeof(maxPacket);
    AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket);
    if (!maxPacket)
        maxPacket = 1500;

    long produced = 0;
    for (int i = 0; i < 4096; ++i) {
        UInt32 packets = 1;
        AudioStreamPacketDescription description;
        unsigned char buffer[4096];
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 1;
        list.mBuffers[0].mDataByteSize = maxPacket < sizeof(buffer) ? maxPacket : (UInt32)sizeof(buffer);
        list.mBuffers[0].mData = buffer;
        if (AudioConverterFillComplexBuffer(converter, feedKeyedOnDescriptionPointer, source,
                &packets, &list, &description) != noErr || !packets)
            break;
        produced += packets;
    }
    AudioConverterDispose(converter);
    return produced;
}

int main(void)
{
    static unsigned char pcm[kFrames * kBytesPerFrame];
    for (int i = 0; i < kFrames; ++i) {
        int value = (int)(8388607.0 * sin(i * 0.01));
        pcm[i * 3 + 0] = value & 0xFF;
        pcm[i * 3 + 1] = (value >> 8) & 0xFF;
        pcm[i * 3 + 2] = (value >> 16) & 0xFF;
    }
    static float conforming[kFrames];
    static float underReporting[kFrames];

    // The shape AudioFileReaderCocoa has: one "packet" standing for the whole block.
    Source under = { pcm, sizeof(pcm), 1, 0, 0 };
    check("under-reporting LPCM caller decodes every frame",
        decode(lpcm24(), &under, underReporting, kFrames), kFrames);

    // A caller that reports the true count, which needs nothing from the shim.
    Source exact = { pcm, sizeof(pcm), kFrames, 0, 0 };
    check("conforming CBR caller decodes every frame",
        decode(lpcm24(), &exact, conforming, kFrames), kFrames);

    check("both callers produce the same samples",
        memcmp(conforming, underReporting, sizeof(conforming)) == 0, 1);

    // A variable-bitrate input format fixes no packet size, so the callback is reached unaltered.
    AudioStreamBasicDescription mp3;
    memset(&mp3, 0, sizeof(mp3));
    mp3.mSampleRate = 44100;
    mp3.mFormatID = kAudioFormatMPEGLayer3;
    mp3.mFramesPerPacket = 1152;
    mp3.mChannelsPerFrame = 1;
    Source vbr = { pcm, sizeof(pcm), 1, 0, 0 };
    static float ignored[kFrames];
    decode(mp3, &vbr, ignored, kFrames);
    check("VBR caller's own callback is reached", vbr.callbacks > 0, 1);

    // Half a second of 48 kHz mono is 24000 frames, which AAC's 1024-frame packets cover 23 times
    // with a partial one left inside the encoder; the bound leaves room for its priming. A count
    // this far below the frames supplied means the encoder was fed nothing: without the shim the
    // whole half second yields four packets.
    enum { kEncodeFrames = 24000, kEncodeFloor = 20 };
    static float tone[kEncodeFrames];
    for (int i = 0; i < kEncodeFrames; ++i)
        tone[i] = 0.25f * (float)sin(i * 0.05);
    Source described = { (const unsigned char *)tone, sizeof(tone), 1, 0, 0 };
    long describedPackets = encodeToAAC(&described);
    printf("  %-56s %ld packets\n", "(AAC packets from 24000 frames)", describedPackets);
    check("LPCM caller keyed on the description pointer feeds the AAC encoder every frame",
        describedPackets >= kEncodeFloor, 1);

    if (failures) {
        printf("FAILED: %d\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
