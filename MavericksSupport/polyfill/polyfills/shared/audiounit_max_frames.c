/*
 * AudioUnitInitialize, and the two calls that end a unit's life -- DELIBERATE OVERRIDES of functions
 * 10.9 has.
 *
 * kAudioUnitProperty_MaximumFramesPerSlice is the largest render the unit promises it can serve. On
 * an output unit 10.9 leaves it at whatever kAudioDevicePropertyBufferFrameSize happened to be when
 * the unit was initialized. That size belongs to the DEVICE and is shared by every client in the
 * process and on the machine, so any of them may raise it afterwards -- WebKit's own
 * MediaSessionManagerCocoa::updateSessionState() asks AudioSession for kLowPowerVideoBufferSize
 * (4096 frames) as soon as a media session exists. The HAL then asks the unit for more frames than
 * it declared and every render fails with kAudioUnitErr_TooManyFramesToProcess (-10874); the unit
 * never recovers and its audio stops for good. Newer CoreAudio keeps the declaration at or above the
 * buffer frame size of the device the unit drives, for the life of the unit, and that is the contract
 * this supplies -- as a superset, the top of every OUTPUT device's supported range, because a
 * kAudioUnitSubType_DefaultOutput unit -- what AudioOutputUnitAdaptor::configure creates -- follows
 * the default output device and can move to any of them. A unit that does move is declared again
 * against the device it now drives, from a listener on its own
 * kAudioOutputUnitProperty_CurrentDevice. 10.9 accepts the property on a unit that is initialized and
 * even one that is running (measured: set while rendering, st=0, LastRenderError stays 0), so that
 * later raise reaches units that are already playing.
 *
 * AUHAL itself overwrites the declaration from a second direction: its listener on the device's
 * kAudioDevicePropertyBufferFrameSize restates MaximumFramesPerSlice as the device's CURRENT buffer
 * frame size on every initialized unit whenever any client changes that size
 * (AUHAL::DeviceListener -> AUConverterBase::SetupAllConverters -> SetMaxFramesPerSlice, in the 10.9
 * CoreAudio component). gst-plugins-good's osxaudio lowers the shared device buffer to its 10 ms packet
 * -- 441, 480 or 220 frames by content rate -- so every other running output unit in the process
 * drops to that, and WebKit's next raise to 4096 reaches the IO thread before the raise's own
 * notification reaches the unit: one render of 4096 frames against a declaration of 441. The unit
 * publishes each restatement through kAudioUnitProperty_MaximumFramesPerSlice, synchronously, on the
 * thread that made it, and accepts the nested set that follows, so the ceiling is declared again from
 * a listener on that property and is back in place before AUHAL's own listener returns.
 *
 * That failing render is also the entry to a three-way deadlock on 10.9: AUBase::DoRender reports
 * the error through AUHAL::PropertyChanged from the IO thread while it holds the HAL IO-context
 * lock, which blocks on AUHAL's CAMutex, which the CoreAudio dispatch queue holds inside the
 * device-property listener the same size change triggered -- and that listener is itself waiting on
 * the HAL IO-context lock. Every later thread that touches the unit joins the pile-up.
 *
 * Correct for any caller: the unit is asked for its own device (kAudioOutputUnitProperty_CurrentDevice),
 * which answers for AUHAL and DefaultOutput alike. A unit that does not carry that property holds no
 * device, is not what the HAL hands a device-sized slice to, and is left alone. An existing larger
 * declaration is left alone too.
 *
 * Initialize restates the property too, scaling it by the ratio between the client format's rate and
 * the device's; the listener above answers that restatement from inside it, and the value is read
 * back afterwards to report a unit that came out below the ceiling anyway.
 *
 * The declaration is auxiliary: this override forwards to the real AudioUnitInitialize
 * unconditionally and answers with ITS status. A machine with no readable output device -- audio
 * disabled, every device unplugged, or a hot-unplug landing between the device-list read and the
 * range read -- must still initialize its units, so a status from this file's own property traffic is
 * never allowed to become the initialize's answer. It is reported on stderr instead of discarded, and
 * the unit is tracked anyway so the next device change retries it.
 *
 * AudioUnitUninitialize and AudioComponentInstanceDispose are here rather than with the rest of the
 * re-homed entry points in polyfills/c/AudioToolbox.c because they are this file's other half: they
 * are how a tracked unit stops being one, and the gap archive needs that pair as much as WebKit does.
 *
 * Two callers cross this boundary here: WebCore's AudioOutputUnitAdaptor::configure, which reaches
 * it by soft-link (the registry entries below answer that dlsym), and gst-plugins-good's
 * gst_core_audio_initialize_impl, which calls it directly and binds the force-loaded definition.
 *
 * Plain C: deps/build_deps.sh compiles this file into the gap archive that force-loads into every
 * media dylib, and polyfill/build-polyfill.sh compiles it into libpolyfill.a for WebKit, where
 * WK_POLYFILL_REGISTERED adds the registry entries.
 *
 * 10.9's functions are reached by naming their image, with NSAddImage and NSLookupSymbolInImage --
 * the pre-dlopen dyld API, deprecated since 10.5 but present and working on 10.9. They are used
 * here because they work identically in both products: the gap archive carries no registry and no
 * dlsym override, so it has nothing to ask a provider name about.
 */

#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <syslog.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

static const char kWKAudioUnitImage[] = "/System/Library/Frameworks/AudioUnit.framework/Versions/A/AudioUnit";
static const char kWKCoreAudioImage[] = "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio";

typedef OSStatus (*wk_audio_unit_initialize_fn)(AudioUnit);
typedef OSStatus (*wk_audio_unit_get_property_fn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
    AudioUnitElement, void *, UInt32 *);
typedef OSStatus (*wk_audio_unit_set_property_fn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
    AudioUnitElement, const void *, UInt32);
typedef OSStatus (*wk_audio_object_get_property_data_fn)(AudioObjectID,
    const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
typedef OSStatus (*wk_audio_object_get_property_data_size_fn)(AudioObjectID,
    const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
typedef OSStatus (*wk_audio_unit_uninitialize_fn)(AudioUnit);
typedef void (*wk_audio_unit_property_listener_proc)(void *, AudioUnit, AudioUnitPropertyID,
    AudioUnitScope, AudioUnitElement);
typedef OSStatus (*wk_audio_unit_add_property_listener_fn)(AudioUnit, AudioUnitPropertyID,
    wk_audio_unit_property_listener_proc, void *);
typedef OSStatus (*wk_audio_unit_remove_property_listener_fn)(AudioUnit, AudioUnitPropertyID,
    wk_audio_unit_property_listener_proc, void *);
typedef OSStatus (*wk_audio_component_instance_dispose_fn)(AudioComponentInstance);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void *wk_symbol_in_image(const char *image, const char *symbol)
{
    const struct mach_header *header = NSAddImage(image, NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    if (!header)
        return 0;

    NSSymbol found = NSLookupSymbolInImage(header, symbol, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR);
    return found ? NSAddressOfSymbol(found) : 0;
}

#pragma clang diagnostic pop

/* One address each, resolved on first use and kept. A racing second caller resolves the same
 * address out of the same image, so an unsynchronized write publishes a value already equal to
 * what any other thread would have written. */
static wk_audio_unit_initialize_fn wk_system_audio_unit_initialize(void)
{
    static wk_audio_unit_initialize_fn cached;
    if (!cached)
        cached = (wk_audio_unit_initialize_fn)wk_symbol_in_image(kWKAudioUnitImage, "_AudioUnitInitialize");
    return cached;
}

static wk_audio_unit_get_property_fn wk_system_audio_unit_get_property(void)
{
    static wk_audio_unit_get_property_fn cached;
    if (!cached)
        cached = (wk_audio_unit_get_property_fn)wk_symbol_in_image(kWKAudioUnitImage, "_AudioUnitGetProperty");
    return cached;
}

static wk_audio_unit_add_property_listener_fn wk_system_audio_unit_add_property_listener(void)
{
    static wk_audio_unit_add_property_listener_fn cached;
    if (!cached)
        cached = (wk_audio_unit_add_property_listener_fn)wk_symbol_in_image(kWKAudioUnitImage,
            "_AudioUnitAddPropertyListener");
    return cached;
}

static wk_audio_unit_remove_property_listener_fn wk_system_audio_unit_remove_property_listener(void)
{
    static wk_audio_unit_remove_property_listener_fn cached;
    if (!cached)
        cached = (wk_audio_unit_remove_property_listener_fn)wk_symbol_in_image(kWKAudioUnitImage,
            "_AudioUnitRemovePropertyListenerWithUserData");
    return cached;
}

static wk_audio_unit_set_property_fn wk_system_audio_unit_set_property(void)
{
    static wk_audio_unit_set_property_fn cached;
    if (!cached)
        cached = (wk_audio_unit_set_property_fn)wk_symbol_in_image(kWKAudioUnitImage, "_AudioUnitSetProperty");
    return cached;
}

static wk_audio_object_get_property_data_fn wk_system_audio_object_get_property_data(void)
{
    static wk_audio_object_get_property_data_fn cached;
    if (!cached)
        cached = (wk_audio_object_get_property_data_fn)wk_symbol_in_image(kWKCoreAudioImage,
            "_AudioObjectGetPropertyData");
    return cached;
}

static wk_audio_object_get_property_data_size_fn wk_system_audio_object_get_property_data_size(void)
{
    static wk_audio_object_get_property_data_size_fn cached;
    if (!cached)
        cached = (wk_audio_object_get_property_data_size_fn)wk_symbol_in_image(kWKCoreAudioImage,
            "_AudioObjectGetPropertyDataSize");
    return cached;
}

static wk_audio_unit_uninitialize_fn wk_system_audio_unit_uninitialize(void)
{
    static wk_audio_unit_uninitialize_fn cached;
    if (!cached)
        cached = (wk_audio_unit_uninitialize_fn)wk_symbol_in_image(kWKAudioUnitImage, "_AudioUnitUninitialize");
    return cached;
}

static wk_audio_component_instance_dispose_fn wk_system_audio_component_instance_dispose(void)
{
    static wk_audio_component_instance_dispose_fn cached;
    if (!cached)
        cached = (wk_audio_component_instance_dispose_fn)wk_symbol_in_image(kWKAudioUnitImage,
            "_AudioComponentInstanceDispose");
    return cached;
}

static const AudioObjectPropertyAddress kWKFrameSizeRangeAddress = {
    kAudioDevicePropertyBufferFrameSizeRange,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMaster
};

static const AudioObjectPropertyAddress kWKDevicesAddress = {
    kAudioHardwarePropertyDevices,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMaster
};

/* Whether this device can play. An input-only device never asks an output unit for a slice, so its
 * range is not part of the ceiling; the property carries one entry per output stream, and its SIZE
 * alone answers the question. */
static int wk_device_has_output(wk_audio_object_get_property_data_size_fn getObjectPropertySize,
    AudioDeviceID device)
{
    AudioObjectPropertyAddress outputStreamsAddress = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMaster
    };
    UInt32 outputStreamsSize = 0;
    if (getObjectPropertySize(device, &outputStreamsAddress, 0, 0, &outputStreamsSize))
        return 0;
    return outputStreamsSize > 0;
}

/* The largest slice any output device on this machine can ask for. A device that cannot answer for
 * a buffer frame size range is skipped rather than failing the initialize -- it cannot ask for a
 * slice through a range it does not have either. `fallback` is the unit's own device, which answers
 * when the machine's device list cannot be read at all. */
static UInt32 wk_largest_output_device_maximum_frames(wk_audio_object_get_property_data_fn getObjectProperty,
    wk_audio_object_get_property_data_size_fn getObjectPropertySize, AudioDeviceID fallback, OSStatus *outStatus)
{
    AudioValueRange frameSizeRange = { 0, 0 };
    UInt32 frameSizeRangeSize;
    UInt32 devicesSize = 0;
    UInt32 maximum = 0;

    *outStatus = noErr;

    if (!getObjectPropertySize(kAudioObjectSystemObject, &kWKDevicesAddress, 0, 0, &devicesSize)
        && devicesSize >= sizeof(AudioDeviceID)) {
        AudioDeviceID *devices = (AudioDeviceID *)malloc(devicesSize);
        if (devices) {
            if (!getObjectProperty(kAudioObjectSystemObject, &kWKDevicesAddress, 0, 0, &devicesSize, devices)) {
                UInt32 count = devicesSize / (UInt32)sizeof(AudioDeviceID);
                UInt32 i;
                for (i = 0; i < count; ++i) {
                    if (!wk_device_has_output(getObjectPropertySize, devices[i]))
                        continue;
                    frameSizeRangeSize = sizeof(frameSizeRange);
                    if (getObjectProperty(devices[i], &kWKFrameSizeRangeAddress, 0, 0, &frameSizeRangeSize, &frameSizeRange))
                        continue;
                    if ((UInt32)frameSizeRange.mMaximum > maximum)
                        maximum = (UInt32)frameSizeRange.mMaximum;
                }
            }
            free(devices);
        }
    }

    if (maximum)
        return maximum;

    frameSizeRangeSize = sizeof(frameSizeRange);
    *outStatus = getObjectProperty(fallback, &kWKFrameSizeRangeAddress, 0, 0, &frameSizeRangeSize, &frameSizeRange);
    return *outStatus ? 0 : (UInt32)frameSizeRange.mMaximum;
}

/* The ceiling most recently computed by this copy of the file. It is a property of the machine's
 * device set, not of any unit: the largest slice any output device can ask for. wk_maximum_frames_changed
 * reads it instead of computing one, because that listener runs inside AUHAL's restatement, after the
 * smaller value is stored and before the set made here replaces it; the device enumeration behind
 * wk_largest_output_device_maximum_frames is a millisecond of HAL round trips, and a render that starts
 * in that interval fails. A racing write publishes the same value, or a newer ceiling from the same
 * device set, so the read is unsynchronized. */
static UInt32 wk_ceiling_cache;

/* A unit that comes out of initialize undeclared renders until the device buffer outgrows it and then
 * stops for good, so it is said out loud rather than returned into a status nothing reads. It goes to
 * syslog, where CoreAudio writes the kAudioUnitErr_TooManyFramesToProcess this predicts: the two lines
 * then sit together, and a WebContent XPC service has no stderr anyone reads. */
static void wk_report_undeclared(AudioUnit unit, const char *what, OSStatus status)
{
    syslog(LOG_ERR, "[wk_polyfill] AudioUnitInitialize: unit %p keeps its own MaximumFramesPerSlice: "
                    "%s (status %d).", (void *)unit, what, (int)status);
}

/* One unit's declaration, raised to `ceiling`. A larger one is left alone, and a unit that does not
 * carry the property at all is not an error. */
static OSStatus wk_raise_unit_ceiling(wk_audio_unit_get_property_fn getUnitProperty,
    wk_audio_unit_set_property_fn setUnitProperty, AudioUnit unit, UInt32 ceiling)
{
    UInt32 declared = 0;
    UInt32 declaredSize = sizeof(declared);
    OSStatus status = getUnitProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &declared, &declaredSize);
    if (status == kAudioUnitErr_InvalidProperty)
        return noErr;
    if (status)
        return status;
    if (declared >= ceiling)
        return noErr;

    return setUnitProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &ceiling, sizeof(ceiling));
}

/* The unit's ceiling belongs to the DEVICE it drives, so it is revisited when that changes -- a
 * kAudioUnitSubType_DefaultOutput unit follows the default output device, and a device that was not
 * present when the unit was initialized can report a larger range than the one that was. 10.9 accepts
 * the property on an initialized and running unit, so the raise happens in place.
 *
 * Both listeners are attached to the UNIT, and CoreAudio owns that association: they fire only while
 * the unit is alive, and disposing the unit takes the registrations with it. There is no list of live
 * units anywhere in this file. That matters because this file is force-loaded into every media dylib
 * and into each of WebKit's frameworks, so the process holds many copies of it; a list would be one
 * copy's private idea of which units exist, and a unit initialized through one image and disposed
 * through another would leave a dangling entry behind. Per-unit state cannot be shared wrongly
 * because it is not shared at all.
 *
 * 10.9 delivers both notifications synchronously from inside the call that changed the property, and
 * accepts the nested set that follows (measured: st=0, and the declaration reads back). */
static void wk_current_device_changed(void *context, AudioUnit unit, AudioUnitPropertyID property,
    AudioUnitScope scope, AudioUnitElement element)
{
    wk_audio_unit_get_property_fn getUnitProperty = wk_system_audio_unit_get_property();
    wk_audio_unit_set_property_fn setUnitProperty = wk_system_audio_unit_set_property();
    wk_audio_object_get_property_data_fn getObjectProperty = wk_system_audio_object_get_property_data();
    wk_audio_object_get_property_data_size_fn getObjectPropertySize = wk_system_audio_object_get_property_data_size();
    AudioDeviceID device = kAudioDeviceUnknown;
    UInt32 deviceSize = sizeof(device);
    UInt32 ceiling;
    OSStatus status;

    (void)context;
    (void)scope;
    (void)element;
    if (property != kAudioOutputUnitProperty_CurrentDevice)
        return;
    if (!getUnitProperty || !setUnitProperty || !getObjectProperty || !getObjectPropertySize)
        return;

    if (getUnitProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, &deviceSize))
        return;

    ceiling = wk_largest_output_device_maximum_frames(getObjectProperty, getObjectPropertySize,
        device, &status);
    if (status || !ceiling) {
        wk_report_undeclared(unit, "the device it moved to reported no buffer frame size range", status);
        return;
    }
    wk_ceiling_cache = ceiling;

    status = wk_raise_unit_ceiling(getUnitProperty, setUnitProperty, unit, ceiling);
    if (status)
        wk_report_undeclared(unit, "the unit refused the declaration after moving device", status);
}

/* AUHAL's restatement of the declaration (see the top of the file), answered from the notification it
 * publishes. The set made here publishes the property in turn, which re-enters this listener once with
 * the ceiling already in place. */
static void wk_maximum_frames_changed(void *context, AudioUnit unit, AudioUnitPropertyID property,
    AudioUnitScope scope, AudioUnitElement element)
{
    wk_audio_unit_get_property_fn getUnitProperty = wk_system_audio_unit_get_property();
    wk_audio_unit_set_property_fn setUnitProperty = wk_system_audio_unit_set_property();
    UInt32 ceiling = wk_ceiling_cache;
    OSStatus status;

    (void)context;
    (void)scope;
    (void)element;
    if (property != kAudioUnitProperty_MaximumFramesPerSlice || !ceiling)
        return;
    if (!getUnitProperty || !setUnitProperty)
        return;

    status = wk_raise_unit_ceiling(getUnitProperty, setUnitProperty, unit, ceiling);
    if (status)
        wk_report_undeclared(unit, "the unit refused the declaration after restating it", status);
}

/* Both teardown calls drop the registration before forwarding, so the proc cannot be reached through
 * a unit this file has finished with. */
static void wk_forget_unit(AudioUnit unit)
{
    wk_audio_unit_remove_property_listener_fn removeListener = wk_system_audio_unit_remove_property_listener();
    if (removeListener) {
        removeListener(unit, kAudioOutputUnitProperty_CurrentDevice, wk_current_device_changed, 0);
        removeListener(unit, kAudioUnitProperty_MaximumFramesPerSlice, wk_maximum_frames_changed, 0);
    }
}

/* The ceiling this unit is declared, or 0 for a unit this file does not declare. Only an OUTPUT unit
 * is declared: it is the one the HAL hands a device-sized slice to, and the device buffer size is the
 * quantity that outgrows the declaration. A unit that does not answer
 * kAudioOutputUnitProperty_CurrentDevice holds no device and is left alone -- declaring a bare
 * converter or mixer is a host's job, and no macOS does it from the unit's own initialize.
 * *outTracked reports whether the unit is one whose ceiling a later device change has to revisit. */
static UInt32 wk_declare_device_maximum_frames(AudioUnit unit, int *outTracked)
{
    wk_audio_unit_get_property_fn getUnitProperty = wk_system_audio_unit_get_property();
    wk_audio_unit_set_property_fn setUnitProperty = wk_system_audio_unit_set_property();
    wk_audio_object_get_property_data_fn getObjectProperty = wk_system_audio_object_get_property_data();
    wk_audio_object_get_property_data_size_fn getObjectPropertySize = wk_system_audio_object_get_property_data_size();
    AudioDeviceID device = kAudioDeviceUnknown;
    UInt32 deviceSize = sizeof(device);
    UInt32 ceiling;
    OSStatus status;

    *outTracked = 0;
    if (!getUnitProperty || !setUnitProperty || !getObjectProperty || !getObjectPropertySize) {
        wk_report_undeclared(unit, "AudioUnit/CoreAudio property entry points did not resolve", noErr);
        return 0;
    }

    status = getUnitProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &device, &deviceSize);
    if (status == kAudioUnitErr_InvalidProperty || status == kAudioUnitErr_InvalidElement)
        return 0;                       /* Not an output unit: it holds no device and is not declared. */
    if (status) {
        wk_report_undeclared(unit, "the unit would not answer which device it drives", status);
        return 0;
    }

    /* Tracked from here on, whether or not the raise below lands: an output unit whose ceiling could
     * not be read today is exactly the one a later device change has to revisit. */
    *outTracked = 1;

    ceiling = wk_largest_output_device_maximum_frames(getObjectProperty, getObjectPropertySize,
        device, &status);
    if (status || !ceiling) {
        wk_report_undeclared(unit, "no output device reported a buffer frame size range", status);
        return 0;
    }
    wk_ceiling_cache = ceiling;

    status = wk_raise_unit_ceiling(getUnitProperty, setUnitProperty, unit, ceiling);
    if (status) {
        wk_report_undeclared(unit, "the unit refused the declaration", status);
        return 0;
    }
    return ceiling;
}


OSStatus AudioUnitInitialize(AudioUnit inUnit)
{
    wk_audio_unit_initialize_fn system = wk_system_audio_unit_initialize();
    if (!system) {
        fprintf(stderr, "[wk_polyfill] AudioUnitInitialize: no _AudioUnitInitialize export in %s; "
                        "the unit cannot be initialized.\n", kWKAudioUnitImage);
        fflush(stderr);
        return kAudioUnitErr_FailedInitialization;
    }

    int tracked = 0;
    UInt32 ceiling = wk_declare_device_maximum_frames(inUnit, &tracked);

    /* Watched before the real initialize, so a device change during it is not missed. The real
     * initialize restates the declaration too, and the second listener answers that restatement the
     * same way it answers AUHAL's later ones. */
    if (tracked) {
        wk_audio_unit_add_property_listener_fn addListener = wk_system_audio_unit_add_property_listener();
        if (addListener) {
            addListener(inUnit, kAudioOutputUnitProperty_CurrentDevice, wk_current_device_changed, 0);
            addListener(inUnit, kAudioUnitProperty_MaximumFramesPerSlice, wk_maximum_frames_changed, 0);
        }
    }

    OSStatus status = system(inUnit);
    if (status) {
        if (tracked)
            wk_forget_unit(inUnit);
        return status;
    }

    /* Initialize restates the declaration, scaling it by the ratio between the client format's rate
     * and the device's (512 frames at a 44.1 kHz device with a 48 kHz client comes out as 558), and
     * wk_maximum_frames_changed answers that restatement from inside it. The value is read back here
     * only to report a unit that came out below the ceiling anyway. */
    if (ceiling) {
        wk_audio_unit_get_property_fn getUnitProperty = wk_system_audio_unit_get_property();
        if (getUnitProperty) {
            UInt32 declared = 0;
            UInt32 declaredSize = sizeof(declared);
            OSStatus read = getUnitProperty(inUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &declared, &declaredSize);
            if (read)
                wk_report_undeclared(inUnit, "the declaration cannot be read back after initialize", read);
            else if (declared < ceiling)
                wk_report_undeclared(inUnit, "the unit reports a smaller maximum than it accepted", noErr);
        }
    }
    return status;
}

OSStatus AudioUnitUninitialize(AudioUnit inUnit)
{
    wk_audio_unit_uninitialize_fn system = wk_system_audio_unit_uninitialize();

    wk_forget_unit(inUnit);
    if (!system)
        return kAudioUnitErr_CannotDoInCurrentContext;
    return system(inUnit);
}

OSStatus AudioComponentInstanceDispose(AudioComponentInstance inInstance)
{
    wk_audio_component_instance_dispose_fn system = wk_system_audio_component_instance_dispose();

    wk_forget_unit((AudioUnit)inInstance);
    if (!system)
        return kAudioUnitErr_CannotDoInCurrentContext;
    return system(inInstance);
}

#ifdef WK_POLYFILL_REGISTERED
/* Registered so WK_POLYFILL_REPORT lists the overrides, the shadow gate reads a stated intent, and
 * the dlsym override answers WebCore's soft-links with these definitions. The entries are written
 * out by hand so the bodies above compile with no wk_polyfill.h, which is how the vendored builds
 * take them. Provider "AudioToolbox", with the rest of the AudioUnit entry points in
 * polyfills/c/AudioToolbox.c: that is the framework upstream's PAL/pal/cf/AudioToolboxSoftLink.cpp
 * opens for them, and the one 10.9 does not have them in. */
WK_PF_ENTRY(AudioUnitInitialize, "AudioToolbox", &AudioUnitInitialize, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(AudioUnitUninitialize, "AudioToolbox", &AudioUnitUninitialize, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
WK_PF_ENTRY(AudioComponentInstanceDispose, "AudioToolbox", &AudioComponentInstanceDispose, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES);
#endif
