// The AudioUnitInitialize override (polyfills/shared/audiounit_max_frames.c) and the AudioUnit entry
// points re-homed to AudioToolbox (polyfills/c/AudioToolbox.c). An OUTPUT unit must come out of
// initialize declaring the largest slice ANY output device on this machine can ask for, because a
// kAudioUnitSubType_DefaultOutput unit follows the default output device. A unit that holds no output
// device is left as it is -- declaring one is a host's job. An existing larger declaration must survive, and
// the re-homed forwards must reach the real implementations. A device arriving after the unit is
// The comparisons are inequalities because AudioUnitInitialize restates the value in the unit's own
// time base -- a 44.1 kHz client on a 48 kHz device comes out of initialize reading 8468 for a 4608
// declaration -- so what a unit owes is "at least the ceiling", never "exactly" it. A unit
// initialized must raise the declaration in place, which the probe triggers by setting the unit's own
// kAudioOutputUnitProperty_CurrentDevice; 10.9 accepts the maximum on an initialized and running unit,
// which the probe also asserts. AUHAL restates the declaration as the device's buffer frame size from
// its own device listener whenever anything in this process changes that size, and the HAL delivers it
// on this process's main run loop: the probe lowers the default device's buffer under a running unit
// the way a second osxaudio sink does, pumps the run loop, raises it again, and requires the ceiling to
// have held throughout and no render to have failed.
// Declaring the ceiling is auxiliary: a unit whose ceiling cannot be read must still initialize, so
// the probe checks that a unit with no determinable ceiling comes back noErr.
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static void *systemSymbol(const char *symbol)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/AudioUnit.framework/Versions/A/AudioUnit",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, symbol, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

static AudioUnit newUnit(OSType type, OSType subtype)
{
    AudioComponentDescription description = { type, subtype, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent component = AudioComponentFindNext(0, &description);
    AudioUnit unit = 0;
    if (component)
        AudioComponentInstanceNew(component, &unit);
    return unit;
}

static UInt32 maximumFramesPerSlice(AudioUnit unit)
{
    UInt32 frames = 0;
    UInt32 size = sizeof(frames);
    AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &frames, &size);
    return frames;
}

static OSStatus renderSilence(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
    UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    (void)context; (void)flags; (void)timestamp; (void)bus; (void)frames;
    for (UInt32 i = 0; i < data->mNumberBuffers; ++i)
        memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    return noErr;
}

// The HAL delivers device property notifications on the main run loop unless a client moves them.
static void pumpRunLoop(double seconds)
{
    CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < until)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}

static UInt32 rangeMaximum(AudioDeviceID device)
{
    AudioObjectPropertyAddress address = { kAudioDevicePropertyBufferFrameSizeRange,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioValueRange range = { 0, 0 };
    UInt32 size = sizeof(range);
    if (AudioObjectGetPropertyData(device, &address, 0, 0, &size, &range))
        return 0;
    return (UInt32)range.mMaximum;
}

// Computed here from the raw CoreAudio API, so the expected ceiling is arrived at independently of
// the code under test.
static UInt32 largestOutputDeviceMaximum(unsigned *outputDeviceCount)
{
    AudioObjectPropertyAddress devicesAddress = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectPropertyAddress outputStreams = { kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMaster };
    UInt32 size = 0, maximum = 0, i, count;
    AudioDeviceID *devices;

    *outputDeviceCount = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, 0, &size) || !size)
        return 0;
    devices = (AudioDeviceID *)malloc(size);
    if (!devices)
        return 0;
    if (!AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, 0, &size, devices)) {
        count = size / (UInt32)sizeof(AudioDeviceID);
        for (i = 0; i < count; ++i) {
            UInt32 streamsSize = 0;
            UInt32 deviceMaximum;
            if (AudioObjectGetPropertyDataSize(devices[i], &outputStreams, 0, 0, &streamsSize) || !streamsSize)
                continue;
            ++*outputDeviceCount;
            deviceMaximum = rangeMaximum(devices[i]);
            if (deviceMaximum > maximum)
                maximum = deviceMaximum;
        }
    }
    free(devices);
    return maximum;
}

int main(void)
{
    unsigned outputDevices = 0;
    UInt32 expected = largestOutputDeviceMaximum(&outputDevices);

    check(systemSymbol("_AudioUnitInitialize") != 0, "10.9's AudioUnitInitialize is reachable for comparison");
    check(systemSymbol("_AudioUnitInitialize") != (void *)AudioUnitInitialize,
        "the linked AudioUnitInitialize is the archive's, not 10.9's");
    check(systemSymbol("_AudioOutputUnitStart") != (void *)AudioOutputUnitStart,
        "the linked AudioOutputUnitStart is the archive's re-homed forward");
    check(systemSymbol("_AudioComponentInstanceNew") != (void *)AudioComponentInstanceNew,
        "the linked AudioComponentInstanceNew is the archive's re-homed forward");

    check(outputDevices > 0, "this host has at least one output device");
    check(expected > 0, "an output device reports a buffer frame size range");

    AudioObjectPropertyAddress defaultDeviceAddress = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioDeviceID defaultDevice = kAudioDeviceUnknown;
    UInt32 defaultSize = sizeof(defaultDevice);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultDeviceAddress, 0, 0, &defaultSize, &defaultDevice);
    check(defaultDevice != kAudioDeviceUnknown, "this host has a default output device");
    check(expected >= rangeMaximum(defaultDevice), "the ceiling covers the default output device");

    AudioUnit output = newUnit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput);
    check(output != 0, "a default output unit can be instantiated through the re-homed forward");
    if (output) {
        UInt32 small = 441;
        AudioUnitSetProperty(output, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &small, sizeof(small));
        check(AudioUnitInitialize(output) == noErr, "initialize succeeds on an output unit");
        check(maximumFramesPerSlice(output) >= expected,
            "the initialized unit declares every output device's largest slice");

        // A declaration pushed below the ceiling on an initialized unit -- which also establishes that
        // 10.9 accepts the property on one -- is raised again from inside that very set.
        UInt32 lowered = 441;
        check(AudioUnitSetProperty(output, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &lowered, sizeof(lowered)) == noErr, "the property is settable on an initialized unit");
        check(maximumFramesPerSlice(output) >= expected, "a declaration lowered on the live unit is restored in place");

        AudioDeviceID current = kAudioDeviceUnknown;
        UInt32 currentSize = sizeof(current);
        check(AudioUnitGetProperty(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &current, &currentSize) == noErr, "the unit answers which device it drives");
        check(AudioUnitSetProperty(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &current, sizeof(current)) == noErr, "the unit's device can be set on a live unit");
        check(maximumFramesPerSlice(output) >= expected,
            "the declaration holds across a device change on the live unit");

        check(AudioOutputUnitStart(output) == noErr, "the re-homed AudioOutputUnitStart runs the unit");
        check(AudioOutputUnitStop(output) == noErr, "the re-homed AudioOutputUnitStop stops it");
        check(AudioUnitUninitialize(output) == noErr, "the re-homed AudioUnitUninitialize releases it");
        AudioComponentInstanceDispose(output);
    }

    AudioUnit roomy = newUnit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput);
    if (roomy) {
        UInt32 larger = expected * 2;
        AudioUnitSetProperty(roomy, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &larger, sizeof(larger));
        check(AudioUnitInitialize(roomy) == noErr, "initialize succeeds with a larger declaration already set");
        check(maximumFramesPerSlice(roomy) >= larger, "a larger existing declaration is left alone");
        AudioUnitUninitialize(roomy);
        AudioComponentInstanceDispose(roomy);
    }

    // An AUHAL whose client format runs at a different rate from its device: initialize RECOMPUTES
    // the declaration, scaling it by the rate ratio, so a unit declared before initialize can come out
    // carrying a few hundred frames. This is the case the HAL then kills with
    // kAudioUnitErr_TooManyFramesToProcess once the process's buffer frame size goes above it.
    AudioDeviceID defaultOutput = kAudioDeviceUnknown;
    UInt32 defaultOutputSize = sizeof(defaultOutput);
    AudioObjectPropertyAddress defaultOutputAddress = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultOutputAddress, 0, 0,
            &defaultOutputSize, &defaultOutput) == noErr && defaultOutput != kAudioDeviceUnknown) {
        Float64 deviceRate = 0;
        UInt32 deviceRateSize = sizeof(deviceRate);
        AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMaster };
        AudioObjectGetPropertyData(defaultOutput, &rateAddress, 0, 0, &deviceRateSize, &deviceRate);

        AudioUnit resampling = newUnit(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
        check(resampling != 0, "a HAL output unit can be instantiated");
        if (resampling && deviceRate > 0) {
            AudioStreamBasicDescription clientFormat;
            memset(&clientFormat, 0, sizeof(clientFormat));
            clientFormat.mSampleRate = deviceRate > 45000.0 ? 44100.0 : 48000.0;
            clientFormat.mFormatID = kAudioFormatLinearPCM;
            clientFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
            clientFormat.mBytesPerPacket = 8;
            clientFormat.mFramesPerPacket = 1;
            clientFormat.mBytesPerFrame = 8;
            clientFormat.mChannelsPerFrame = 2;
            clientFormat.mBitsPerChannel = 32;
            AudioUnitSetProperty(resampling, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &defaultOutput, sizeof(defaultOutput));
            check(AudioUnitSetProperty(resampling, kAudioUnitProperty_StreamFormat,
                      kAudioUnitScope_Input, 0, &clientFormat, sizeof(clientFormat)) == noErr,
                "a client format at a rate the device does not run can be set");
            check(AudioUnitInitialize(resampling) == noErr, "initialize succeeds with a resampling client format");
            check(maximumFramesPerSlice(resampling) >= expected,
                "a resampling output unit still declares the ceiling after initialize");
            AudioUnitUninitialize(resampling);
            AudioComponentInstanceDispose(resampling);
        } else if (resampling)
            AudioComponentInstanceDispose(resampling);
    }

    // A unit whose ceiling cannot be determined must still initialize: the declaration is auxiliary,
    // and a status from this override's own property traffic must never become the initialize's answer.
    // On a machine with no readable output device that is every unit in the process.
    AudioUnit generic = newUnit(kAudioUnitType_Output, kAudioUnitSubType_GenericOutput);
    check(generic != 0, "a generic output unit can be instantiated");
    if (generic) {
        check(AudioUnitInitialize(generic) == noErr, "initialize succeeds whatever the ceiling lookup answers");
        AudioUnitUninitialize(generic);
        AudioComponentInstanceDispose(generic);
    }

    // A unit that holds no output device is left exactly as it was: the HAL never hands it a
    // device-sized slice directly, and declaring a bare converter is the job of whatever hosts the
    // chain. Asserting the declaration is UNCHANGED is what keeps this override off units it has no
    // business touching.
    AudioUnit converter = newUnit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    check(converter != 0, "a format converter unit can be instantiated");
    if (converter) {
        AudioDeviceID unitDevice = kAudioDeviceUnknown;
        UInt32 unitDeviceSize = sizeof(unitDevice);
        check(AudioUnitGetProperty(converter, kAudioOutputUnitProperty_CurrentDevice,
                  kAudioUnitScope_Global, 0, &unitDevice, &unitDeviceSize) == kAudioUnitErr_InvalidProperty,
            "the converter holds no output device");
        UInt32 before = maximumFramesPerSlice(converter);
        check(before < expected, "the converter's default declaration is below the ceiling");
        check(AudioUnitInitialize(converter) == noErr, "initialize succeeds on a unit with no output device");
        check(maximumFramesPerSlice(converter) == before,
            "a unit with no output device keeps its own declaration");
        AudioUnitUninitialize(converter);
        AudioComponentInstanceDispose(converter);
    }

    // Another client lowering the shared device buffer under a running unit: AUHAL's device listener
    // restates the unit's declaration as that size, and the next raise must not find it there.
    AudioUnit held = newUnit(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
    check(held != 0, "a HAL output unit can be instantiated for the device buffer test");
    if (held && defaultDevice != kAudioDeviceUnknown) {
        AudioObjectPropertyAddress bufferAddress = { kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
        UInt32 original = 0;
        UInt32 originalSize = sizeof(original);
        UInt32 packet = 441;
        UInt32 lowPowerVideo = 4096;
        OSStatus lastRenderError = noErr;
        UInt32 lastRenderErrorSize = sizeof(lastRenderError);
        AURenderCallbackStruct silence = { renderSilence, 0 };

        AudioObjectGetPropertyData(defaultDevice, &bufferAddress, 0, 0, &originalSize, &original);
        AudioUnitSetProperty(held, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &silence, sizeof(silence));
        check(AudioUnitInitialize(held) == noErr, "initialize succeeds on the held unit");
        check(AudioOutputUnitStart(held) == noErr, "the held unit runs");
        pumpRunLoop(0.2);

        check(AudioObjectSetPropertyData(defaultDevice, &bufferAddress, 0, 0, sizeof(packet), &packet) == noErr,
            "another client lowers the device buffer to a 10 ms packet");
        pumpRunLoop(0.5);
        check(maximumFramesPerSlice(held) >= expected,
            "the declaration holds after the device buffer is lowered under the running unit");

        check(AudioObjectSetPropertyData(defaultDevice, &bufferAddress, 0, 0, sizeof(lowPowerVideo), &lowPowerVideo) == noErr,
            "the device buffer is raised to kLowPowerVideoBufferSize again");
        pumpRunLoop(0.5);
        check(maximumFramesPerSlice(held) >= expected, "the declaration holds after the raise");
        AudioUnitGetProperty(held, kAudioUnitProperty_LastRenderError, kAudioUnitScope_Global, 0,
            &lastRenderError, &lastRenderErrorSize);
        check(lastRenderError == noErr, "no render failed across the lowering and the raise");

        AudioOutputUnitStop(held);
        AudioUnitUninitialize(held);
        AudioComponentInstanceDispose(held);
        AudioObjectSetPropertyData(defaultDevice, &bufferAddress, 0, 0, sizeof(original), &original);
    }

    // A unit initialized twice, then uninitialized once, must no longer be watched: a device change
    // after that must leave its declaration alone. Measured on the still-live unit, where the
    // difference is a declaration that moves rather than a fault that may or may not happen.
    AudioUnit twice = newUnit(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
    check(twice != 0, "a second output unit can be instantiated");
    if (twice) {
        UInt32 lowered = 441;
        AudioDeviceID device = kAudioDeviceUnknown;
        UInt32 deviceSize = sizeof(device);
        check(AudioUnitInitialize(twice) == noErr, "initialize succeeds");
        check(AudioUnitInitialize(twice) == noErr, "a second initialize on the same unit succeeds");
        check(AudioUnitUninitialize(twice) == noErr, "uninitialize succeeds");
        AudioUnitSetProperty(twice, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &lowered, sizeof(lowered));

        if (AudioUnitGetProperty(twice, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, &deviceSize) == noErr)
            AudioUnitSetProperty(twice, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, sizeof(device));
        check(maximumFramesPerSlice(twice) < expected,
            "a device change no longer reaches a unit this file has finished with");
        AudioComponentInstanceDispose(twice);
    }

    if (failures)
        printf("AudioUnitInitialize probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
