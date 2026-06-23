/*
 * MAVERICKS_BACKPORT: AVSpeechSynthesizer polyfill for macOS 10.9.
 *
 * The Web Speech API synthesis path (PlatformSpeechSynthesizerCocoa.mm) drives
 * AVFoundation's AVSpeechSynthesizer / AVSpeechUtterance / AVSpeechSynthesisVoice,
 * which are 10.14+ and absent on 10.9. PAL soft-links those classes by name
 * (objc_getClass), so providing strong @implementations of them here — compiled
 * into WebCore — satisfies the lookup. They are backed by NSSpeechSynthesizer,
 * which IS available on 10.9 (10.3+ API).
 *
 * This file deliberately does NOT import <AVFoundation/...> or <AVFAudio/...>:
 * on the modern build SDK those headers declare the real AVSpeech* classes, and
 * redeclaring them here would conflict. The consumer compiles against the SDK
 * declarations and messages these runtime classes dynamically; only the method
 * signatures need to line up.
 */

#import "config.h"

#if ENABLE(SPEECH_SYNTHESIS) && PLATFORM(MAC)

#import <AppKit/NSSpeechSynthesizer.h>
#import <Foundation/Foundation.h>

// The AVSpeechBoundary values used by the consumer (mirrors AVFoundation).
typedef NS_ENUM(NSInteger, WK109AVSpeechBoundary) {
    WK109AVSpeechBoundaryImmediate = 0,
    WK109AVSpeechBoundaryWord = 1,
};

@class AVSpeechSynthesisVoice;
@class AVSpeechUtterance;
@class AVSpeechSynthesizer;

// Informal declaration of the AVSpeechSynthesizerDelegate callbacks we send to
// the consumer's wrapper (which conforms to the SDK's AVSpeechSynthesizerDelegate).
@interface NSObject (WK109AVSpeechSynthesizerDelegate)
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didStartSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didPauseSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didContinueSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance;
@end

#pragma mark - AVSpeechSynthesisVoice

@interface AVSpeechSynthesisVoice : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, readonly) BOOL isSystemVoice;
+ (NSArray<AVSpeechSynthesisVoice *> *)speechVoices;
+ (NSArray<AVSpeechSynthesisVoice *> *)speechVoicesIncludingSuperCompact;
+ (NSString *)currentLanguageCode;
+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language;
+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier;
// The backing NSSpeechSynthesizer voice name.
@property (nonatomic, copy) NSString *nsVoiceName;
@end

static NSString *normalizeLanguage(NSString *locale)
{
    // NSVoiceLocaleIdentifier is e.g. "en_US"; the Web Speech API uses "en-US".
    return [locale stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

@implementation AVSpeechSynthesisVoice {
    NSString *_identifier;
    NSString *_name;
    NSString *_language;
    NSString *_nsVoiceName;
}

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize language = _language;
@synthesize nsVoiceName = _nsVoiceName;

- (BOOL)isSystemVoice { return YES; }

+ (AVSpeechSynthesisVoice *)voiceForNSVoiceName:(NSString *)nsVoiceName
{
    if (!nsVoiceName)
        return nil;
    NSDictionary *attrs = [NSSpeechSynthesizer attributesForVoice:nsVoiceName];
    if (!attrs)
        return nil;
    AVSpeechSynthesisVoice *voice = [[AVSpeechSynthesisVoice alloc] init];
    voice.nsVoiceName = nsVoiceName;
    voice.identifier = nsVoiceName;
    voice.name = attrs[NSVoiceName] ?: nsVoiceName;
    NSString *locale = attrs[NSVoiceLocaleIdentifier];
    voice.language = locale ? normalizeLanguage(locale) : @"en-US";
    return voice;
}

+ (NSArray<AVSpeechSynthesisVoice *> *)speechVoices
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *nsVoice in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoice];
        if (voice)
            [result addObject:voice];
    }
    return result;
}

+ (NSArray<AVSpeechSynthesisVoice *> *)speechVoicesIncludingSuperCompact
{
    return [self speechVoices];
}

+ (NSString *)currentLanguageCode
{
    AVSpeechSynthesisVoice *def = [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
    if (def.language.length)
        return def.language;
    NSString *lang = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode];
    return lang.length ? lang : @"en-US";
}

+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language
{
    if (!language.length)
        return [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
    NSString *target = [normalizeLanguage(language) lowercaseString];
    NSString *targetPrefix = [[target componentsSeparatedByString:@"-"] firstObject];
    AVSpeechSynthesisVoice *prefixMatch = nil;
    for (NSString *nsVoice in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoice];
        NSString *vlang = [voice.language lowercaseString];
        if ([vlang isEqualToString:target])
            return voice;
        if (!prefixMatch && [[[vlang componentsSeparatedByString:@"-"] firstObject] isEqualToString:targetPrefix])
            prefixMatch = voice;
    }
    if (prefixMatch)
        return prefixMatch;
    return [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
}

+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier
{
    if (!identifier.length)
        return nil;
    return [self voiceForNSVoiceName:identifier];
}

@end

#pragma mark - AVSpeechUtterance

@interface AVSpeechUtterance : NSObject
@property (nonatomic, copy) NSString *speechString;
@property (nonatomic) float rate;
@property (nonatomic) float volume;
@property (nonatomic) float pitchMultiplier;
@property (nonatomic, strong) AVSpeechSynthesisVoice *voice;
+ (instancetype)speechUtteranceWithString:(NSString *)string;
@end

@implementation AVSpeechUtterance
+ (instancetype)speechUtteranceWithString:(NSString *)string
{
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] init];
    u.speechString = string;
    u.rate = 0.5; // AVSpeechUtteranceDefaultSpeechRate
    u.volume = 1.0;
    u.pitchMultiplier = 1.0;
    return u;
}
@end

#pragma mark - AVSpeechSynthesizer

@interface AVSpeechSynthesizer : NSObject
@property (nonatomic, weak) id delegate;
- (void)speakUtterance:(AVSpeechUtterance *)utterance;
- (void)pauseSpeakingAtBoundary:(WK109AVSpeechBoundary)boundary;
- (void)continueSpeaking;
- (void)stopSpeakingAtBoundary:(WK109AVSpeechBoundary)boundary;
@end

@implementation AVSpeechSynthesizer {
    NSSpeechSynthesizer *_nsSynth;
    NSMutableArray<AVSpeechUtterance *> *_queue;
    AVSpeechUtterance *_current;
    BOOL _stopping;
}

+ (void)load
{
    // Force this translation unit (and thus the AVSpeech* class metadata) to be
    // retained in WebCore so objc_getClass() finds it via PAL's soft-link.
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _nsSynth = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
    _nsSynth.delegate = (id)self;
    _queue = [NSMutableArray array];
    return self;
}

// Map an AVSpeech rate (0..1, default 0.5) to an NSSpeechSynthesizer rate
// (words/minute; ~175 is a typical default), clamped to a sane range.
static float nsRateForAVRate(float avRate)
{
    float wpm = avRate * 350.0f;
    if (wpm < 80.0f)
        wpm = 80.0f;
    if (wpm > 400.0f)
        wpm = 400.0f;
    return wpm;
}

- (void)startNext
{
    if (_current || !_queue.count)
        return;
    _current = _queue.firstObject;

    if (_current.voice.nsVoiceName)
        [_nsSynth setVoice:_current.voice.nsVoiceName];
    _nsSynth.rate = nsRateForAVRate(_current.rate);
    _nsSynth.volume = _current.volume;

    _stopping = NO;
    BOOL ok = [_nsSynth startSpeakingString:_current.speechString ?: @""];
    if (!ok) {
        // Couldn't start: treat as immediately finished so the queue drains.
        AVSpeechUtterance *u = _current;
        _current = nil;
        [_queue removeObject:u];
        id d = self.delegate;
        if ([d respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [d speechSynthesizer:self didCancelSpeechUtterance:u];
        [self startNext];
        return;
    }

    id d = self.delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:didStartSpeechUtterance:)])
        [d speechSynthesizer:self didStartSpeechUtterance:_current];
}

- (void)speakUtterance:(AVSpeechUtterance *)utterance
{
    if (!utterance)
        return;
    [_queue addObject:utterance];
    [self startNext];
}

- (void)pauseSpeakingAtBoundary:(WK109AVSpeechBoundary)boundary
{
    if (!_current)
        return;
    [_nsSynth pauseSpeakingAtBoundary:(boundary == WK109AVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    id d = self.delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:didPauseSpeechUtterance:)])
        [d speechSynthesizer:self didPauseSpeechUtterance:_current];
}

- (void)continueSpeaking
{
    if (!_current)
        return;
    [_nsSynth continueSpeaking];
    id d = self.delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:didContinueSpeechUtterance:)])
        [d speechSynthesizer:self didContinueSpeechUtterance:_current];
}

- (void)stopSpeakingAtBoundary:(WK109AVSpeechBoundary)boundary
{
    _stopping = YES;
    [_queue removeAllObjects];
    [_nsSynth stopSpeakingAtBoundary:(boundary == WK109AVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    // didFinishSpeaking: (finished == NO) will deliver the cancel callback.
    if (!_nsSynth.isSpeaking && _current) {
        AVSpeechUtterance *u = _current;
        _current = nil;
        id d = self.delegate;
        if ([d respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [d speechSynthesizer:self didCancelSpeechUtterance:u];
    }
}

#pragma mark NSSpeechSynthesizerDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
    AVSpeechUtterance *u = _current;
    if (!u)
        return;
    _current = nil;
    [_queue removeObject:u];

    id d = self.delegate;
    if (finishedSpeaking && !_stopping) {
        if ([d respondsToSelector:@selector(speechSynthesizer:didFinishSpeechUtterance:)])
            [d speechSynthesizer:self didFinishSpeechUtterance:u];
    } else {
        if ([d respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [d speechSynthesizer:self didCancelSpeechUtterance:u];
    }

    _stopping = NO;
    [self startNext];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakWord:(NSRange)characterRange ofString:(NSString *)string
{
    if (!_current)
        return;
    id d = self.delegate;
    if ([d respondsToSelector:@selector(speechSynthesizer:willSpeakRangeOfSpeechString:utterance:)])
        [d speechSynthesizer:self willSpeakRangeOfSpeechString:characterRange utterance:_current];
}

@end

#endif // ENABLE(SPEECH_SYNTHESIS) && PLATFORM(MAC)
