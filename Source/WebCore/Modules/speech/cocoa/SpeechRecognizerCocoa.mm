// MAVERICKS_BACKPORT: runtime-absent framework — the real Cocoa SpeechRecognizer uses SFSpeechRecognizer
// (Speech.framework, 10.15+), unavailable on Mavericks, so this file was originally stubbed empty. But HAVE(SPEECHRECOGNIZER)
// is 1 on Cocoa, which excludes the generic no-op fallbacks in SpeechRecognizer.cpp — leaving
// SpeechRecognizer::{startRecognition,dataCaptured,abortRecognition,stopRecognition} UNDEFINED in
// WebCore.framework. Safari survived via lazy binding (Web Speech recognition rarely invoked), but ANY
// RTLD_NOW dlopen of our WebKit (which forces immediate symbol resolution) then failed — e.g. QuickLook's
// Web2.qldisplay HTML-preview plug-in: "Symbol not found: WebCore::SpeechRecognizer::startRecognition".
// Provide ALL FOUR methods here so WebCore is self-contained for immediate-binding clients AND so the
// degradation is clean: startRecognition() reports a clean failure (the page gets a 'service-not-allowed'
// error rather than silently capturing the mic with no results and never ending), and abort/stop deliver
// the terminal End update so the SpeechRecognition object completes instead of hanging. (Previously only
// startRecognition/dataCaptured were defined here; abort/stopRecognition fell through to libpolyfill's
// return-0 no-op stubs, which never sent End.)
#include "config.h"
#include "SpeechRecognizer.h"
#include "SpeechRecognitionUpdate.h"
#include <wtf/MediaTime.h>

namespace WebCore {

// MAVERICKS_BACKPORT: no SFSpeechRecognizer on 10.9 — drop captured audio (no recognition task to feed).
void SpeechRecognizer::dataCaptured(const MediaTime&, const PlatformAudioData&, const AudioStreamDescription&, size_t)
{
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     auto buffer = createAudioSampleBuffer(data, description, m_currentAudioSampleTime, sampleCount);
//     [m_task audioSamplesAvailable:buffer.get()];
//     m_currentAudioSampleTime = PAL::CMTimeAdd(m_currentAudioSampleTime, PAL::toCMTime(MediaTime(sampleCount, description.sampleRate())));
// (end MAVERICKS_BACKPORT restored block)
}

// MAVERICKS_BACKPORT: no SFSpeechRecognizer on 10.9; fail cleanly instead of constructing a WebSpeechRecognizerTask.
bool SpeechRecognizer::startRecognition(bool, SpeechRecognitionConnectionClientIdentifier, const String&, bool, bool, uint64_t)
{
    // No SFSpeechRecognizer on 10.9 — fail cleanly so start() emits a service-not-allowed error instead
    // of proceeding to capture the microphone for a recognition that can never produce results.
    return false;
}

// MAVERICKS_BACKPORT: no SFSpeechRecognizer on 10.9 — abort by delivering the terminal End update (below) so the SpeechRecognition object completes instead of hanging.
void SpeechRecognizer::abortRecognition()
{
    // MAVERICKS_BACKPORT: terminal End update (no real SFSpeechRecognitionTask to abort on 10.9).
    m_delegateCallback(SpeechRecognitionUpdate::create(clientIdentifier(), SpeechRecognitionUpdateType::End));
}

// MAVERICKS_BACKPORT: no SFSpeechRecognizer on 10.9 — stop by delivering the terminal End update (below) so the SpeechRecognition object completes instead of hanging.
void SpeechRecognizer::stopRecognition()
{
    // MAVERICKS_BACKPORT: terminal End update (no real SFSpeechRecognitionTask to stop on 10.9).
    m_delegateCallback(SpeechRecognitionUpdate::create(clientIdentifier(), SpeechRecognitionUpdateType::End));
}

} // namespace WebCore
// MAVERICKS_BACKPORT: no HAVE(SPEECHRECOGNIZER) #if/#endif wrapper — these methods are defined
// unconditionally on 10.9 (the conditionally-compiled upstream version is empty on this port).
