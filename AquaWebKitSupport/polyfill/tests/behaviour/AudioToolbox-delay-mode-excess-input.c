// The AudioConverterReset that follows a kAudioCodecPropertyDelayMode set in polyfills/c/
// AudioToolboxOpus.c. 10.9 re-initializes the codec behind the converter for that property, and
// CodecConverter::CheckInitialize then builds fresh CABufferList2s whose data-pointer arrays it never
// writes, while the excess-input byte and packet counts keep their values -- so the next pull feeds
// the codec a never-written pointer. AudioSampleBufferConverter::gradualDecoderRefreshCount round-trips
// the delay mode on a live AAC encode converter to read the optimal-mode prime info, which is where
// MediaRecorder and WebCodecs meet it.
//
// Three arms: an encode that carries excess input across the round trip keeps producing packets at the
// rate the same encode does without it, 2048-frame pulls -- which stop the encoder dead after one
// packet when the set is left unrepaired -- keep producing too, and an encode that carries no excess
// across the round trip is unchanged.

#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <stdlib.h>
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

enum { kSampleRate = 44100, kFills = 40 };

typedef struct {
    const unsigned char *pcm;
    UInt32 bytes;
    int served;
} Source;

static OSStatus feed(AudioConverterRef converter, UInt32 *packets, AudioBufferList *data,
    AudioStreamPacketDescription **descriptions, void *userData)
{
    Source *source = (Source *)userData;
    (void)converter;
    if (descriptions)
        *descriptions = NULL;
    if (source->served) {
        *packets = 0;
        return 'MOAR'; // kNoMoreDataErr, the WebCore-private starved-input answer.
    }
    data->mBuffers[0].mNumberChannels = 1;
    data->mBuffers[0].mDataByteSize = source->bytes;
    data->mBuffers[0].mData = (void *)source->pcm;
    *packets = source->bytes / 4;
    source->served = 1;
    return noErr;
}

// The body of AudioSampleBufferConverter::gradualDecoderRefreshCount(): read the codec's delay mode,
// switch it to Optimal, read the prime info there, switch it back.
static void readOptimalPrimeInfo(AudioConverterRef converter)
{
    UInt32 size = sizeof(UInt32);
    UInt32 originalDelayMode = 0;
    if (AudioConverterGetProperty(converter, kAudioCodecPropertyDelayMode, &size, &originalDelayMode))
        return;
    UInt32 optimal = kAudioCodecDelayMode_Optimal;
    if (AudioConverterSetProperty(converter, kAudioCodecPropertyDelayMode, size, &optimal))
        return;
    UInt32 primeSize = sizeof(AudioCodecPrimeInfo);
    AudioCodecPrimeInfo primeInfo = { 0, 0 };
    AudioConverterGetProperty(converter, kAudioCodecPropertyPrimeInfo, &primeSize, &primeInfo);
    AudioConverterSetProperty(converter, kAudioCodecPropertyDelayMode, size, &originalDelayMode);
}

// Encodes kFills buffers of framesPerPull frames each and answers the number of packets produced,
// running the delay-mode round trip once the first packet is out when roundTrip is set.
static int encode(int framesPerPull, int roundTrip)
{
    AudioStreamBasicDescription source, destination;
    memset(&source, 0, sizeof(source));
    memset(&destination, 0, sizeof(destination));
    source.mFormatID = kAudioFormatLinearPCM;
    source.mSampleRate = kSampleRate;
    source.mChannelsPerFrame = 1;
    source.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    source.mBitsPerChannel = 32;
    source.mFramesPerPacket = 1;
    source.mBytesPerPacket = source.mBytesPerFrame = 4;
    destination.mFormatID = kAudioFormatMPEG4AAC;
    destination.mChannelsPerFrame = 1;
    destination.mSampleRate = kSampleRate;
    UInt32 size = sizeof(destination);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &size, &destination))
        return -1;

    AudioConverterRef converter = NULL;
    if (AudioConverterNew(&source, &destination, &converter))
        return -1;
    UInt32 bitRate = 192000;
    AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitRate), &bitRate);
    UInt32 maxPacketSize = 0;
    size = sizeof(maxPacketSize);
    if (AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacketSize) || !maxPacketSize) {
        AudioConverterDispose(converter);
        return -1;
    }

    unsigned char *out = malloc(maxPacketSize);
    unsigned char *pcm = calloc(1, (size_t)framesPerPull * 4);
    AudioStreamPacketDescription descriptions[4];
    int produced = 0, refreshed = 0;

    for (int fill = 0; fill < kFills; ++fill) {
        Source input = { pcm, (UInt32)framesPerPull * 4, 0 };
        union { AudioBufferList list; char bytes[128]; } filled;
        filled.list.mNumberBuffers = 1;
        filled.list.mBuffers[0].mNumberChannels = 1;
        filled.list.mBuffers[0].mDataByteSize = maxPacketSize;
        filled.list.mBuffers[0].mData = out;
        UInt32 packets = 1;
        OSStatus status = AudioConverterFillComplexBuffer(converter, feed, &input, &packets, &filled.list, descriptions);
        if (status && status != 'MOAR')
            break;
        produced += packets;
        if (packets && roundTrip && !refreshed) {
            refreshed = 1;
            readOptimalPrimeInfo(converter);
        }
    }

    free(out);
    free(pcm);
    AudioConverterDispose(converter);
    return produced;
}

int main(void)
{
    printf("AudioToolbox delay-mode round trip over pending excess input\n");

    // 1536-frame pulls leave the encoder holding excess input when the first packet comes out, which
    // is the shape a capture source with a 35 ms render interval hands MediaRecorder.
    int withRoundTrip = encode(1536, 1);
    check("an encode carrying excess input survives the round trip", withRoundTrip > 0, 1);
    check("it keeps producing at the rate it does without the round trip", withRoundTrip, encode(1536, 0));

    // 2048-frame pulls fill the encoder outright, and an unrepaired set stops it after one packet.
    check("2048-frame pulls keep producing across the round trip", encode(2048, 1), encode(2048, 0));

    // 1024-frame pulls are consumed whole, so the converter carries no excess across the round trip.
    check("an encode carrying no excess is unchanged", encode(1024, 1), encode(1024, 0));

    printf("%s\n", failures ? "FAILURES" : "all checks passed");
    return failures ? 1 : 0;
}
