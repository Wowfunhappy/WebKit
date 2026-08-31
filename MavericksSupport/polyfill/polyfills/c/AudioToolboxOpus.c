// AudioToolbox Opus encoding. 10.9's AudioToolbox exports the whole AudioConverter API but its codec
// registry has no Opus ('opus' answers kAudioFormatUnsupportedDataFormatError), while the modern
// AudioToolbox contract WebCore's AudioSampleBufferConverter encodes WebM audio through includes an
// Opus encoder behind the same calls. These replacements serve that contract for Opus-destination
// encode converters, backed by the libopus the private runtime already ships
// (WebCore.framework/Versions/A/Frameworks/gstreamer/lib/libopus.0.dylib); every other converter,
// format and property query is the system's answer untouched.
//
// The Opus converter accepts any LPCM source (interleaved or not, any rate the system's own
// LPCM->LPCM converter can read): a nested system converter deinterleaves and resamples to the
// 48 kHz float the encoder consumes, 20 ms (960-frame) packets come out with real packet
// descriptions, the input callback's own error (WebCore uses 'MOAR' for "no more data yet") is
// propagated exactly as AudioToolbox does, and a zero-packet callback answer drains the resampler
// tail, pads the final frame with silence and flushes the encoder.

#include "wk_polyfill.h"

#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <sys/syslog.h>
#include <stdlib.h>
#include <string.h>

// libopus, resolved lazily from the private runtime. Declarations mirror opus.h/opus_defines.h
// (vendored at Source/ThirdParty/libwebrtc/Source/third_party/opus/src/include).
typedef struct OpusEncoder OpusEncoder;
enum {
    WK_OPUS_APPLICATION_AUDIO = 2049,
    WK_OPUS_SET_BITRATE_REQUEST = 4002,
    WK_OPUS_SET_VBR_REQUEST = 4006,
    WK_OPUS_SET_COMPLEXITY_REQUEST = 4010,
    WK_OPUS_SET_INBAND_FEC_REQUEST = 4012,
    WK_OPUS_SET_PACKET_LOSS_PERC_REQUEST = 4014,
    WK_OPUS_GET_LOOKAHEAD_REQUEST = 4027,
    WK_OPUS_RESET_STATE = 4028,
};

static struct {
    OpusEncoder *(*encoder_create)(int32_t fs, int channels, int application, int *error);
    void (*encoder_destroy)(OpusEncoder *);
    int32_t (*encode_float)(OpusEncoder *, const float *pcm, int frameSize, unsigned char *data, int32_t maxBytes);
    int (*encoder_ctl)(OpusEncoder *, int request, ...);
} wk_opus;

static bool wkOpusLoad(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The private GStreamer runtime lives beside the image this code is linked into
        // (WebCore.framework/Versions/A/Frameworks/gstreamer/lib); the runtime's dylibs reference each
        // other by @loader_path install names, so the path is derived from this image's own location.
        void *lib = NULL;
        Dl_info info;
        if (dladdr((const void *)&wkOpusLoad, &info) && info.dli_fname) {
            char path[1024];
            const char *slash = strrchr(info.dli_fname, '/');
            size_t dirLength = slash ? (size_t)(slash - info.dli_fname) + 1 : 0;
            if (dirLength && dirLength + sizeof("Frameworks/gstreamer/lib/libopus.0.dylib") <= sizeof(path)) {
                memcpy(path, info.dli_fname, dirLength);
                strcpy(path + dirLength, "Frameworks/gstreamer/lib/libopus.0.dylib");
                lib = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
            }
        }
        if (!lib)
            lib = dlopen("libopus.0.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (!lib) {
            syslog(LOG_ERR, "[wk_polyfill] AudioConverter opus: dlopen libopus failed: %s", dlerror());
            return;
        }
        wk_opus.encoder_create = (OpusEncoder *(*)(int32_t, int, int, int *))dlsym(lib, "opus_encoder_create");
        wk_opus.encoder_destroy = (void (*)(OpusEncoder *))dlsym(lib, "opus_encoder_destroy");
        wk_opus.encode_float = (int32_t (*)(OpusEncoder *, const float *, int, unsigned char *, int32_t))dlsym(lib, "opus_encode_float");
        wk_opus.encoder_ctl = (int (*)(OpusEncoder *, int, ...))dlsym(lib, "opus_encoder_ctl");
    });
    return wk_opus.encoder_create && wk_opus.encoder_destroy && wk_opus.encode_float && wk_opus.encoder_ctl;
}

enum { kWKOpusFrameSize = 960 };          // 20 ms at 48 kHz, the packet duration FormatInfo declares.
enum { kWKOpusMaxPacketBytes = 1500 };    // a 20 ms packet peaks at 1275 bytes at OPUS_MAX_BITRATE.
enum { kWKOpusChunkFrames = 4096 };       // frames requested from the caller's input proc per pull.
static const OSStatus kWKOpusInputExhausted = 'wknd'; // nested-resampler sentinel, never escapes.

typedef struct WKOpusConverter {
    AudioStreamBasicDescription sourceFormat;
    AudioStreamBasicDescription destinationFormat;
    OpusEncoder *encoder;
    AudioConverterRef resampler; // system LPCM converter: source -> 48 kHz interleaved float32.
    AudioStreamBasicDescription resampledFormat;

    float *fifo; // 48 kHz interleaved float frames awaiting encoding.
    size_t fifoFrames;
    size_t fifoCapacityFrames;

    // One source chunk in flight between the caller's input proc and the resampler.
    const AudioBufferList *pendingInput;
    UInt32 pendingInputFrames;
    bool pendingInputConsumed;
    bool flushResampler; // tail drain: answer the resampler with a real EOF so it flushes.

    bool sawEOF;      // the caller's input proc answered "0 packets, noErr" (drain).
    bool tailFlushed; // resampler tail drained and final padded frame queued.
    UInt32 bitRate;
} WKOpusConverter;

// Handles owned here are tracked in a registry, looked up by pointer identity. The system's
// AudioConverterRef values on 10.9 are opaque non-pointer cookies (small, consecutive, misaligned),
// so an unknown handle must never be dereferenced to classify it.
enum { kWKOpusMaxConverters = 32 };
static WKOpusConverter * volatile wkOpusLiveConverters[kWKOpusMaxConverters];

static bool wkOpusRegister(WKOpusConverter *c)
{
    for (int i = 0; i < kWKOpusMaxConverters; ++i) {
        if (__sync_bool_compare_and_swap(&wkOpusLiveConverters[i], NULL, c))
            return true;
    }
    return false;
}

static void wkOpusUnregister(WKOpusConverter *c)
{
    for (int i = 0; i < kWKOpusMaxConverters; ++i)
        __sync_bool_compare_and_swap(&wkOpusLiveConverters[i], c, NULL);
}

static WKOpusConverter *wkOpusConverter(AudioConverterRef converter)
{
    for (int i = 0; i < kWKOpusMaxConverters; ++i) {
        WKOpusConverter *c = wkOpusLiveConverters[i];
        if (c && (AudioConverterRef)c == converter)
            return c;
    }
    return NULL;
}

static void wkOpusFifoEnsure(WKOpusConverter *c, size_t additionalFrames)
{
    size_t needed = c->fifoFrames + additionalFrames;
    if (needed <= c->fifoCapacityFrames)
        return;
    size_t capacity = c->fifoCapacityFrames ? c->fifoCapacityFrames : 8192;
    while (capacity < needed)
        capacity *= 2;
    c->fifo = realloc(c->fifo, capacity * c->destinationFormat.mChannelsPerFrame * sizeof(float));
    c->fifoCapacityFrames = capacity;
}

// Serves the one pending source chunk to the nested resampler. Once the chunk is consumed it
// reports exhaustion with a sentinel error so the resampler keeps its state, except during a tail
// drain, where a zero-packet noErr answer makes the resampler flush its buffered frames.
static OSStatus wkOpusResamplerInput(AudioConverterRef converter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    (void)converter;
    WKOpusConverter *c = (WKOpusConverter *)inUserData;
    if (outDataPacketDescription)
        *outDataPacketDescription = NULL;
    if (c->pendingInputConsumed || !c->pendingInput) {
        *ioNumberDataPackets = 0;
        return c->flushResampler ? noErr : kWKOpusInputExhausted;
    }
    if (ioData->mNumberBuffers != c->pendingInput->mNumberBuffers)
        return kAudioConverterErr_UnspecifiedError;
    for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
        ioData->mBuffers[i] = c->pendingInput->mBuffers[i];
    *ioNumberDataPackets = c->pendingInputFrames;
    c->pendingInputConsumed = true;
    return noErr;
}

// Runs source frames (or, with a null chunk, the resampler's tail) into the 48 kHz float FIFO.
// Defined after the AudioConverterFillComplexBuffer replacement whose original it calls.
static OSStatus wkOpusResampleChunk(WKOpusConverter *c, const AudioBufferList *chunk, UInt32 chunkFrames);

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioFormatGetProperty, (AudioFormatPropertyID inPropertyID, UInt32 inSpecifierSize, const void *inSpecifier, UInt32 *ioPropertyDataSize, void *outPropertyData))
{
    if (inPropertyID == kAudioFormatProperty_FormatInfo && ioPropertyDataSize && *ioPropertyDataSize >= sizeof(AudioStreamBasicDescription) && outPropertyData
        && ((AudioStreamBasicDescription *)outPropertyData)->mFormatID == kAudioFormatOpus) {
        AudioStreamBasicDescription *asbd = (AudioStreamBasicDescription *)outPropertyData;
        (void)inSpecifierSize;
        (void)inSpecifier;
        // Opus runs at the 48 kHz family only; the modern framework answers the same way, which is
        // what lets WebCore's computeSampleRate retry at 48 kHz.
        double rate = asbd->mSampleRate;
        if (rate != 48000 && rate != 24000 && rate != 16000 && rate != 12000 && rate != 8000)
            return kAudioCodecUnsupportedFormatError;
        asbd->mFormatFlags = 0;
        asbd->mBytesPerPacket = 0;
        asbd->mFramesPerPacket = (UInt32)(rate / 50); // 20 ms.
        asbd->mBytesPerFrame = 0;
        asbd->mBitsPerChannel = 0;
        return noErr;
    }
    return WK_ORIGINAL(AudioFormatGetProperty)(inPropertyID, inSpecifierSize, inSpecifier, ioPropertyDataSize, outPropertyData);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterDispose, (AudioConverterRef inAudioConverter))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterDispose)(inAudioConverter);
    wkOpusUnregister(c);
    wk_opus.encoder_destroy(c->encoder);
    WK_ORIGINAL(AudioConverterDispose)(c->resampler);
    free(c->fifo);
    free(c);
    return noErr;
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterNew, (const AudioStreamBasicDescription *inSourceFormat, const AudioStreamBasicDescription *inDestinationFormat, AudioConverterRef *outAudioConverter))
{
    if (!inSourceFormat || !inDestinationFormat || !outAudioConverter
        || inDestinationFormat->mFormatID != kAudioFormatOpus
        || inSourceFormat->mFormatID != kAudioFormatLinearPCM)
        return WK_ORIGINAL(AudioConverterNew)(inSourceFormat, inDestinationFormat, outAudioConverter);

    if (!wkOpusLoad()) {
        return kAudioFormatUnsupportedDataFormatError;
    }
    if (inDestinationFormat->mSampleRate != 48000 || !inDestinationFormat->mChannelsPerFrame || inDestinationFormat->mChannelsPerFrame > 2)
        return kAudioFormatUnsupportedDataFormatError;

    WKOpusConverter *c = calloc(1, sizeof(WKOpusConverter));
    c->sourceFormat = *inSourceFormat;
    c->destinationFormat = *inDestinationFormat;
    c->destinationFormat.mFramesPerPacket = kWKOpusFrameSize;
    c->destinationFormat.mBytesPerPacket = 0;
    c->destinationFormat.mBytesPerFrame = 0;
    c->destinationFormat.mBitsPerChannel = 0;
    c->bitRate = 0;

    c->resampledFormat.mSampleRate = 48000;
    c->resampledFormat.mFormatID = kAudioFormatLinearPCM;
    c->resampledFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    c->resampledFormat.mChannelsPerFrame = c->destinationFormat.mChannelsPerFrame;
    c->resampledFormat.mBitsPerChannel = 32;
    c->resampledFormat.mBytesPerFrame = 4 * c->resampledFormat.mChannelsPerFrame;
    c->resampledFormat.mFramesPerPacket = 1;
    c->resampledFormat.mBytesPerPacket = c->resampledFormat.mBytesPerFrame;

    OSStatus status = WK_ORIGINAL(AudioConverterNew)(&c->sourceFormat, &c->resampledFormat, &c->resampler);
    if (status != noErr) {
        free(c);
        return status;
    }

    int opusError = 0;
    c->encoder = wk_opus.encoder_create(48000, (int)c->destinationFormat.mChannelsPerFrame, WK_OPUS_APPLICATION_AUDIO, &opusError);
    if (!c->encoder) {
        WK_ORIGINAL(AudioConverterDispose)(c->resampler);
        free(c);
        return kAudioFormatUnsupportedDataFormatError;
    }

    if (!wkOpusRegister(c)) {
        wk_opus.encoder_destroy(c->encoder);
        WK_ORIGINAL(AudioConverterDispose)(c->resampler);
        free(c);
        return kAudioConverterErr_UnspecifiedError;
    }

    *outAudioConverter = (AudioConverterRef)c;
    return noErr;
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterReset, (AudioConverterRef inAudioConverter))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterReset)(inAudioConverter);
    wk_opus.encoder_ctl(c->encoder, WK_OPUS_RESET_STATE);
    WK_ORIGINAL(AudioConverterReset)(c->resampler);
    c->fifoFrames = 0;
    c->sawEOF = false;
    c->tailFlushed = false;
    return noErr;
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterSetProperty, (AudioConverterRef inAudioConverter, AudioConverterPropertyID inPropertyID, UInt32 inPropertyDataSize, const void *inPropertyData))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterSetProperty)(inAudioConverter, inPropertyID, inPropertyDataSize, inPropertyData);
    switch (inPropertyID) {
    case kAudioConverterEncodeBitRate:
        if (inPropertyDataSize != sizeof(UInt32) || !inPropertyData)
            return kAudioConverterErr_BadPropertySizeError;
        c->bitRate = *(const UInt32 *)inPropertyData;
        wk_opus.encoder_ctl(c->encoder, WK_OPUS_SET_BITRATE_REQUEST, (int32_t)c->bitRate);
        return noErr;
    case kAudioCodecPropertyBitRateControlMode:
        if (inPropertyDataSize != sizeof(UInt32) || !inPropertyData)
            return kAudioConverterErr_BadPropertySizeError;
        wk_opus.encoder_ctl(c->encoder, WK_OPUS_SET_VBR_REQUEST,
            *(const UInt32 *)inPropertyData == kAudioCodecBitRateControlMode_Constant ? 0 : 1);
        return noErr;
    case kAudioCodecPropertyQualitySetting:
        if (inPropertyDataSize != sizeof(UInt32) || !inPropertyData)
            return kAudioConverterErr_BadPropertySizeError;
        // kAudioCodecQuality_Min..Max is 0..0x7F; opus complexity is 0..10.
        wk_opus.encoder_ctl(c->encoder, WK_OPUS_SET_COMPLEXITY_REQUEST, (int32_t)((*(const UInt32 *)inPropertyData * 10) / 0x7F));
        return noErr;
    case 'plsp': // packet-loss percentage, as set by WebCore's Opus encoder options.
        if (inPropertyDataSize != sizeof(UInt32) || !inPropertyData)
            return kAudioConverterErr_BadPropertySizeError;
        wk_opus.encoder_ctl(c->encoder, WK_OPUS_SET_PACKET_LOSS_PERC_REQUEST, (int32_t)*(const UInt32 *)inPropertyData);
        return noErr;
    case 'pfec': // in-band FEC, as set by WebCore's Opus encoder options.
        if (inPropertyDataSize != sizeof(UInt32) || !inPropertyData)
            return kAudioConverterErr_BadPropertySizeError;
        wk_opus.encoder_ctl(c->encoder, WK_OPUS_SET_INBAND_FEC_REQUEST, (int32_t)!!*(const UInt32 *)inPropertyData);
        return noErr;
    case kAudioCodecPropertyDelayMode:
        return inPropertyDataSize == sizeof(UInt32) ? noErr : kAudioConverterErr_BadPropertySizeError;
    case kAudioConverterPrimeInfo:
        return noErr; // the encoder's own lookahead governs; accepted for API compatibility.
    default:
        return kAudioConverterErr_PropertyNotSupported;
    }
}

static UInt32 wkOpusLookaheadFrames(WKOpusConverter *c)
{
    int32_t lookahead = 0;
    wk_opus.encoder_ctl(c->encoder, WK_OPUS_GET_LOOKAHEAD_REQUEST, &lookahead);
    return lookahead > 0 ? (UInt32)lookahead : 0;
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterGetProperty, (AudioConverterRef inAudioConverter, AudioConverterPropertyID inPropertyID, UInt32 *ioPropertyDataSize, void *outPropertyData))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterGetProperty)(inAudioConverter, inPropertyID, ioPropertyDataSize, outPropertyData);
    if (!ioPropertyDataSize || !outPropertyData)
        return kAudioConverterErr_BadPropertySizeError;
    switch (inPropertyID) {
    case kAudioConverterCurrentInputStreamDescription:
        if (*ioPropertyDataSize < sizeof(AudioStreamBasicDescription))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(AudioStreamBasicDescription);
        memcpy(outPropertyData, &c->sourceFormat, sizeof(AudioStreamBasicDescription));
        return noErr;
    case kAudioConverterCurrentOutputStreamDescription:
        if (*ioPropertyDataSize < sizeof(AudioStreamBasicDescription))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(AudioStreamBasicDescription);
        memcpy(outPropertyData, &c->destinationFormat, sizeof(AudioStreamBasicDescription));
        return noErr;
    case kAudioConverterPropertyMaximumOutputPacketSize:
        if (*ioPropertyDataSize < sizeof(UInt32))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(UInt32);
        *(UInt32 *)outPropertyData = kWKOpusMaxPacketBytes;
        return noErr;
    case kAudioConverterPrimeInfo: { // == kAudioCodecPropertyPrimeInfo ('prim'), same layout.
        if (*ioPropertyDataSize < sizeof(AudioConverterPrimeInfo))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(AudioConverterPrimeInfo);
        AudioConverterPrimeInfo *info = (AudioConverterPrimeInfo *)outPropertyData;
        info->leadingFrames = wkOpusLookaheadFrames(c);
        info->trailingFrames = 0;
        return noErr;
    }
    case kAudioCodecPropertyDelayMode:
        if (*ioPropertyDataSize < sizeof(UInt32))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(UInt32);
        *(UInt32 *)outPropertyData = kAudioCodecDelayMode_Compatibility;
        return noErr;
    case kAudioConverterEncodeBitRate:
        if (*ioPropertyDataSize < sizeof(UInt32))
            return kAudioConverterErr_BadPropertySizeError;
        *ioPropertyDataSize = sizeof(UInt32);
        *(UInt32 *)outPropertyData = c->bitRate;
        return noErr;
    default:
        return kAudioConverterErr_PropertyNotSupported;
    }
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterGetPropertyInfo, (AudioConverterRef inAudioConverter, AudioConverterPropertyID inPropertyID, UInt32 *outSize, Boolean *outWritable))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterGetPropertyInfo)(inAudioConverter, inPropertyID, outSize, outWritable);
    UInt32 size;
    switch (inPropertyID) {
    case kAudioConverterCurrentInputStreamDescription:
    case kAudioConverterCurrentOutputStreamDescription:
        size = sizeof(AudioStreamBasicDescription);
        break;
    case kAudioConverterPropertyMaximumOutputPacketSize:
    case kAudioConverterEncodeBitRate:
    case kAudioCodecPropertyDelayMode:
        size = sizeof(UInt32);
        break;
    case kAudioConverterPrimeInfo:
        size = sizeof(AudioConverterPrimeInfo);
        break;
    default:
        return kAudioConverterErr_PropertyNotSupported;
    }
    if (outSize)
        *outSize = size;
    if (outWritable)
        *outWritable = inPropertyID == kAudioConverterEncodeBitRate;
    return noErr;
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioConverterFillComplexBuffer, (AudioConverterRef inAudioConverter, AudioConverterComplexInputDataProc inInputDataProc, void *inInputDataProcUserData, UInt32 *ioOutputDataPacketSize, AudioBufferList *outOutputData, AudioStreamPacketDescription *outPacketDescription))
{
    WKOpusConverter *c = wkOpusConverter(inAudioConverter);
    if (!c)
        return WK_ORIGINAL(AudioConverterFillComplexBuffer)(inAudioConverter, inInputDataProc, inInputDataProcUserData, ioOutputDataPacketSize, outOutputData, outPacketDescription);

    if (!ioOutputDataPacketSize || !outOutputData || !outOutputData->mNumberBuffers)
        return kAudioConverterErr_UnspecifiedError;

    UInt32 wantedPackets = *ioOutputDataPacketSize;
    unsigned char *outBase = outOutputData->mBuffers[0].mData;
    UInt32 outCapacity = outOutputData->mBuffers[0].mDataByteSize;
    UInt32 channels = c->destinationFormat.mChannelsPerFrame;
    UInt32 producedPackets = 0;
    UInt32 usedBytes = 0;
    OSStatus inputStatus = noErr;

    while (producedPackets < wantedPackets) {
        if (c->fifoFrames >= kWKOpusFrameSize) {
            if (outCapacity - usedBytes < kWKOpusMaxPacketBytes && producedPackets)
                break;
            int32_t bytes = wk_opus.encode_float(c->encoder, c->fifo, kWKOpusFrameSize, outBase + usedBytes,
                (int32_t)(outCapacity - usedBytes < kWKOpusMaxPacketBytes ? outCapacity - usedBytes : kWKOpusMaxPacketBytes));
            if (bytes < 0) {
                syslog(LOG_ERR, "[wk_polyfill] AudioConverter opus: opus_encode_float failed: %d", (int)bytes);
                return kAudioConverterErr_UnspecifiedError;
            }
            if (outPacketDescription) {
                outPacketDescription[producedPackets].mStartOffset = usedBytes;
                outPacketDescription[producedPackets].mVariableFramesInPacket = 0;
                outPacketDescription[producedPackets].mDataByteSize = (UInt32)bytes;
            }
            usedBytes += (UInt32)bytes;
            producedPackets++;
            c->fifoFrames -= kWKOpusFrameSize;
            memmove(c->fifo, c->fifo + kWKOpusFrameSize * channels, c->fifoFrames * channels * sizeof(float));
            continue;
        }

        if (c->tailFlushed || inputStatus != noErr)
            break;

        if (c->sawEOF) {
            // Drain the resampler's tail, then zero-pad the remainder up to a full frame boundary.
            c->flushResampler = true;
            OSStatus status = wkOpusResampleChunk(c, NULL, 0);
            c->flushResampler = false;
            if (status != noErr) {
                syslog(LOG_ERR, "[wk_polyfill] AudioConverter opus: resampler tail drain failed: %d", (int)status);
                return status;
            }
            WK_ORIGINAL(AudioConverterReset)(c->resampler);
            size_t remainder = c->fifoFrames % kWKOpusFrameSize;
            if (remainder) {
                size_t pad = kWKOpusFrameSize - remainder;
                wkOpusFifoEnsure(c, pad);
                memset(c->fifo + c->fifoFrames * channels, 0, pad * channels * sizeof(float));
                c->fifoFrames += pad;
            }
            c->tailFlushed = true;
            continue;
        }

        // Pull one chunk from the caller. The list shape must match the source format: one buffer
        // per channel when deinterleaved, one buffer otherwise, with the callee installing pointers.
        UInt32 sourceBuffers = (c->sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? c->sourceFormat.mChannelsPerFrame : 1;
        UInt32 chunkFrames = kWKOpusChunkFrames;
        union { AudioBufferList list; char bytes[sizeof(AudioBufferList) + 8 * sizeof(AudioBuffer)]; } listStorage;
        AudioBufferList *list = &listStorage.list;
        if (sourceBuffers > 9)
            return kAudioConverterErr_UnspecifiedError;
        list->mNumberBuffers = sourceBuffers;
        for (UInt32 i = 0; i < sourceBuffers; ++i) {
            list->mBuffers[i].mNumberChannels = sourceBuffers > 1 ? 1 : c->sourceFormat.mChannelsPerFrame;
            list->mBuffers[i].mDataByteSize = 0;
            list->mBuffers[i].mData = NULL;
        }
        // The source is LPCM, so no packet descriptions are requested; a caller handed a non-null
        // description pointer answers with its (empty) description count instead of the PCM frames.
        inputStatus = inInputDataProc(inAudioConverter, &chunkFrames, list, NULL, inInputDataProcUserData);
        if (inputStatus != noErr)
            continue; // reported to the caller below, after the packets already produced.
        if (!chunkFrames) {
            c->sawEOF = true;
            continue;
        }
        OSStatus status = wkOpusResampleChunk(c, list, chunkFrames);
        if (status != noErr) {
            syslog(LOG_ERR, "[wk_polyfill] AudioConverter opus: resample failed: %d (%u frames)", (int)status, (unsigned)chunkFrames);
            return status;
        }
    }

    // A drain ends once every buffered frame is encoded; the converter then resumes pulling
    // input, matching a system converter that is drained and reset mid-stream.
    if (c->tailFlushed && !c->fifoFrames) {
        c->sawEOF = false;
        c->tailFlushed = false;
    }
    outOutputData->mBuffers[0].mDataByteSize = usedBytes;
    outOutputData->mBuffers[0].mNumberChannels = channels;
    *ioOutputDataPacketSize = producedPackets;
    return inputStatus;
}

// Runs source frames (or, with a null chunk, the resampler's tail) into the 48 kHz float FIFO.
static OSStatus wkOpusResampleChunk(WKOpusConverter *c, const AudioBufferList *chunk, UInt32 chunkFrames)
{
    c->pendingInput = chunk;
    c->pendingInputFrames = chunkFrames;
    c->pendingInputConsumed = chunk == NULL;

    for (;;) {
        UInt32 outFrames = kWKOpusChunkFrames;
        wkOpusFifoEnsure(c, outFrames);
        AudioBufferList out;
        out.mNumberBuffers = 1;
        out.mBuffers[0].mNumberChannels = c->destinationFormat.mChannelsPerFrame;
        out.mBuffers[0].mDataByteSize = outFrames * c->resampledFormat.mBytesPerFrame;
        out.mBuffers[0].mData = c->fifo + c->fifoFrames * c->destinationFormat.mChannelsPerFrame;
        OSStatus status = WK_ORIGINAL(AudioConverterFillComplexBuffer)(c->resampler, wkOpusResamplerInput, c, &outFrames, &out, NULL);
        c->fifoFrames += outFrames;
        if (status == kWKOpusInputExhausted)
            return noErr;
        if (status != noErr)
            return status;
        if (!outFrames)
            return noErr; // fully drained (EOF flush).
    }
}
