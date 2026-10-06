// AudioToolbox: the AudioComponent / AudioUnit / AudioOutputUnit entry points. 10.9 keeps them in
// AudioUnit.framework; 10.10 moved them into AudioToolbox, which is where modern WebKit looks for
// them -- PAL/pal/cf/AudioToolboxSoftLink.{h,cpp} soft-links all of them from AudioToolbox, and on
// this OS every one of those lookups comes back NULL.
//
// Each definition below is registered against provider "AudioToolbox", the framework the soft-link
// opens, and forwards to the real symbol in AudioUnit.framework. WK_SYSTEM names AudioUnit rather
// than the entry's own provider, because the entry's provider is precisely the framework that does
// not have the symbol here. WK_SYSTEM resolves through the REAL dlsym on the AudioUnit handle, which
// the registry never answers for -- an entry answers only a handle that can see its own provider --
// so a forward can never arrive back at the definition it came from.
//
// AudioUnitInitialize, AudioUnitUninitialize and AudioComponentInstanceDispose belong to this set and
// are registered the same way, but their definitions live in polyfills/shared/audiounit_max_frames.c:
// they do more than forward, and GStreamer's osxaudio needs the same bodies through the deps gap
// archive.
//
// kAudioUnitErr_CannotDoInCurrentContext is the answer when AudioUnit.framework cannot be reached at
// all; AudioComponentFindNext answers NULL, which is its documented "no such component".
#include "wk_polyfill.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>

WK_SYSTEM_FN("AudioUnit", AudioComponent, AudioComponentFindNext, (AudioComponent, const AudioComponentDescription *));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioComponentInstanceNew, (AudioComponent, AudioComponentInstance *));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioComponentCopyName, (AudioComponent, CFStringRef *));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioUnitGetProperty, (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioUnitSetProperty, (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioUnitRender, (AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioOutputUnitStart, (AudioUnit));
WK_SYSTEM_FN("AudioUnit", OSStatus, AudioOutputUnitStop, (AudioUnit));

WK_POLYFILL_REPLACES("AudioToolbox", AudioComponent, AudioComponentFindNext,
    (AudioComponent inComponent, const AudioComponentDescription *inDesc))
{
    if (!WK_SYSTEM(AudioComponentFindNext))
        return NULL;
    return WK_SYSTEM(AudioComponentFindNext)(inComponent, inDesc);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioComponentInstanceNew,
    (AudioComponent inComponent, AudioComponentInstance *outInstance))
{
    if (!WK_SYSTEM(AudioComponentInstanceNew))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioComponentInstanceNew)(inComponent, outInstance);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioComponentCopyName,
    (AudioComponent inComponent, CFStringRef *outName))
{
    if (!WK_SYSTEM(AudioComponentCopyName))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioComponentCopyName)(inComponent, outName);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioUnitGetProperty,
    (AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement,
     void *outData, UInt32 *ioDataSize))
{
    if (!WK_SYSTEM(AudioUnitGetProperty))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioUnitGetProperty)(inUnit, inID, inScope, inElement, outData, ioDataSize);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioUnitSetProperty,
    (AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope, AudioUnitElement inElement,
     const void *inData, UInt32 inDataSize))
{
    if (!WK_SYSTEM(AudioUnitSetProperty))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioUnitSetProperty)(inUnit, inID, inScope, inElement, inData, inDataSize);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioUnitRender,
    (AudioUnit inUnit, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
     UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData))
{
    if (!WK_SYSTEM(AudioUnitRender))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioUnitRender)(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioOutputUnitStart, (AudioUnit ci))
{
    if (!WK_SYSTEM(AudioOutputUnitStart))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioOutputUnitStart)(ci);
}

WK_POLYFILL_REPLACES("AudioToolbox", OSStatus, AudioOutputUnitStop, (AudioUnit ci))
{
    if (!WK_SYSTEM(AudioOutputUnitStop))
        return kAudioUnitErr_CannotDoInCurrentContext;
    return WK_SYSTEM(AudioOutputUnitStop)(ci);
}
