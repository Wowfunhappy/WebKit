// AVFoundation: constants modern WebKit references that 10.9's AVFoundation does not export.
#include "wk_polyfill.h"

#import <AVFoundation/AVFoundation.h>

// AVFoundation's speech-synthesis constants (10.14+, absent here). AVSpeechSynthesizer itself is
// polyfilled over NSSpeechSynthesizer in classes/AVFoundation.m; these are the values that go with it.
//
// The three rates are the documented endpoints of AVSpeechUtterance.rate's scale and are the values
// the framework exports on a modern OS. PlatformSpeechSynthesizerCocoa reads Default and Maximum by
// dlsym and interpolates the Web Speech API's rate onto them, so they have to be these numbers for
// the mapping to come out right -- there is nothing OS-specific about them to derive.
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceMinimumSpeechRate, 0.0f);
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceDefaultSpeechRate, 0.5f);
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceMaximumSpeechRate, 1.0f);

// The notification AVSpeechSynthesisVoice posts when the installed voice set changes. 10.9's
// NSSpeechSynthesizer has no equivalent notification, so nothing posts this one and an observer
// simply never fires -- which is the same thing that happens on a modern OS whose voice set never
// changes. It still needs a name: PlatformSpeechSynthesizerCocoa registers for it through a required
// soft-link, which RELEASE_ASSERTs on a missing constant.
// The SDK declares this one without const, so it is defined with WK_PF_ENTRY (WK_POLYFILL_CONST would
// spell it "NSString * const").
NSNotificationName AVSpeechSynthesisAvailableVoicesDidChangeNotification = @"AVSpeechSynthesisAvailableVoicesDidChangeNotification";
WK_PF_ENTRY(AVSpeechSynthesisAvailableVoicesDidChangeNotification, "AVFoundation",
            &AVSpeechSynthesisAvailableVoicesDidChangeNotification, WK_POLYFILL_CONSTANT, WK_POLYFILL_GAP_FILL);

// AVSampleBuffer renderer/layer notification names (10.10-15+, all absent here). WebAVSampleBufferListener
// registers for these by name; an absent name weak-imports to NULL, and -addObserver:selector:name:object:
// treats a nil name as "every notification for this object", which is a different and much broader
// registration than upstream asked for. So they are supplied rather than left NULL.
//
// The two AVSampleBufferAudioRenderer ones can never fire on 10.9 (the class is absent, so no instance
// exists to post them) and the AVSampleBufferDisplayLayer ones are posted by a class 10.9 DOES have but
// whose 10.10+ failure/flush notifications it never sends. Either way nothing on this OS posts them, so
// what matters is that each name is a distinct, stable string — which is exactly what a notification name
// is. The values are the constants' own spelling, as Apple's are.
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerFailedToDecodeNotification,
                  @"AVSampleBufferDisplayLayerFailedToDecodeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey,
                  @"AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification,
                  @"AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification,
                  @"AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification,
                  @"AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferAudioRendererFlushTimeKey,
                  @"AVSampleBufferAudioRendererFlushTimeKey");
