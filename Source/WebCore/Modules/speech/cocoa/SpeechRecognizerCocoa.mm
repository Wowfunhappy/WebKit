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

void SpeechRecognizer::dataCaptured(const MediaTime&, const PlatformAudioData&, const AudioStreamDescription&, size_t)
{
}

bool SpeechRecognizer::startRecognition(bool, SpeechRecognitionConnectionClientIdentifier, const String&, bool, bool, uint64_t)
{
    // No SFSpeechRecognizer on 10.9 — fail cleanly so start() emits a service-not-allowed error instead
    // of proceeding to capture the microphone for a recognition that can never produce results.
    return false;
}

void SpeechRecognizer::abortRecognition()
{
    m_delegateCallback(SpeechRecognitionUpdate::create(clientIdentifier(), SpeechRecognitionUpdateType::End));
}

void SpeechRecognizer::stopRecognition()
{
    m_delegateCallback(SpeechRecognitionUpdate::create(clientIdentifier(), SpeechRecognitionUpdateType::End));
}

} // namespace WebCore
