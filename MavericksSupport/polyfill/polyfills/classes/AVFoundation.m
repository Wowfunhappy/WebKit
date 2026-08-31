// AVFoundation: stubs of the AVFoundation classes 10.9 does not have, built without linking
// AVFoundation (see wk_priv_class.h).
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
// For CMSampleBufferRef in the AVCapturePhotoOutput stub's still-image callback. Header only: no
// CoreMedia symbol is referenced here, so this does not put CoreMedia on the dylib's load commands.
#import <CoreMedia/CMSampleBuffer.h>
#import <objc/runtime.h>

// ==============================================================================================
// AVFoundation
//
// Unlike the stubs in the other classes/ files, every class in this file is reached by NAME: PAL soft-links each one,
// and SOFT_LINK_CLASS_FOR_SOURCE resolves a class with objc_getClass(), which the private runtime
// name deliberately hides from. So each one is registered with WK_POLYFILL_CLASS (mechanism/
// wk_polyfill.h), and the objc_getClass override in wk_polyfill_runtime.c answers WebKit's lookup
// out of that registry. The private name still keeps them invisible to the host app.
//
// These are also the only stubs that need 10.9 classes of their own (AVCaptureDevice,
// AVCaptureStillImageOutput) to do the work. Those are reached through NSClassFromString and a
// protocol-typed cast rather than a compile-time classref, because a classref would put
// AVFoundation on this dylib's load commands -- and this dylib is linked into every WebKit
// framework, so AVFoundation would then be loaded into JavaScriptCore, the NetworkProcess and every
// host app that embeds WebKit, none of which have any reason to load it.

// AVMediaTypeVideo and AVCaptureDevicePositionUnspecified, spelled out for the same reason: reading
// them from AVFoundation would mean linking it. Both values are API contract, not implementation.
#define WK_AV_MEDIA_TYPE_VIDEO @"vide"
enum { WKAVCaptureDevicePositionUnspecified = 0 };

@protocol WKPolyfillAVCaptureDevice <NSObject>
+ (NSArray *)devicesWithMediaType:(NSString *)mediaType;
+ (NSArray *)devices;
- (NSInteger)position;
@end

// AVCaptureDeviceDiscoverySession (10.10+): enumerates capture devices, narrowed by device type,
// media type and position. 10.9 has no device *types* -- the whole AVCaptureDeviceType vocabulary
// arrived with 10.15 -- so the type list cannot narrow anything here and the two filters 10.9 can
// apply are the media type and the position, which is what +devicesWithMediaType: and -position
// give. That is the same set of devices the real class would return on a machine whose cameras all
// predate the type vocabulary, so the answer is right for any caller and not just WebKit's.
WK_PRIV_CLASS(AVCaptureDeviceDiscoverySession) @interface AVCaptureDeviceDiscoverySession : NSObject
+ (instancetype)discoverySessionWithDeviceTypes:(NSArray *)deviceTypes mediaType:(NSString *)mediaType position:(NSInteger)position;
@property (nonatomic, readonly) NSArray *devices;
@end

@implementation AVCaptureDeviceDiscoverySession {
    NSString *_mediaType;
    NSInteger _position;
}

+ (instancetype)discoverySessionWithDeviceTypes:(NSArray *)deviceTypes mediaType:(NSString *)mediaType position:(NSInteger)position
{
    (void)deviceTypes;
    AVCaptureDeviceDiscoverySession *session = [[[self alloc] init] autorelease];
    if (!session)
        return nil;
    session->_mediaType = [mediaType copy];
    session->_position = position;
    return session;
}

- (void)dealloc
{
    [_mediaType release];
    [super dealloc];
}

- (NSArray *)devices
{
    Class<WKPolyfillAVCaptureDevice> captureDevice = (Class<WKPolyfillAVCaptureDevice>)NSClassFromString(@"AVCaptureDevice");
    if (!captureDevice)
        return @[];

    NSArray *devices = _mediaType ? [captureDevice devicesWithMediaType:_mediaType] : [captureDevice devices];
    if (!devices)
        return @[];
    if (_position == WKAVCaptureDevicePositionUnspecified)
        return devices;

    NSMutableArray *matching = [NSMutableArray array];
    for (id<WKPolyfillAVCaptureDevice> device in devices) {
        if ([device position] == _position)
            [matching addObject:device];
    }
    return matching;
}

@end
WK_PRIV_ALIAS(AVCaptureDeviceDiscoverySession);
WK_POLYFILL_CLASS("AVFoundation", AVCaptureDeviceDiscoverySession);

// AVAudioRoutingArbiter (10.15+): asks the system to arbitrate which app owns the audio route
// before a capture/playback session starts, and reports back whether the default device changed.
// 10.9 has no routing-arbitration service at all -- an app simply takes the device -- so the
// faithful implementation of "begin arbitration" on this OS is to grant it: no error, and no
// default-device change, since nothing was rearranged. The completion handler is delivered
// asynchronously because that is the shape of the real API, not because anything here is slow;
// a caller that assumed synchronous delivery would break on a modern OS too.
WK_PRIV_CLASS(AVAudioRoutingArbiter) @interface AVAudioRoutingArbiter : NSObject
+ (instancetype)sharedRoutingArbiter;
- (void)beginArbitrationWithCategory:(NSInteger)category completionHandler:(void (^)(BOOL defaultDeviceChanged, NSError *error))handler;
- (void)leaveArbitration;
@end

@implementation AVAudioRoutingArbiter

+ (instancetype)sharedRoutingArbiter
{
    static AVAudioRoutingArbiter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[AVAudioRoutingArbiter alloc] init];
    });
    return shared;
}

- (void)beginArbitrationWithCategory:(NSInteger)category completionHandler:(void (^)(BOOL, NSError *))handler
{
    (void)category;
    if (!handler)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(NO, nil);
    });
}

- (void)leaveArbitration
{
}

@end
WK_PRIV_ALIAS(AVAudioRoutingArbiter);
WK_POLYFILL_CLASS("AVFoundation", AVAudioRoutingArbiter);

// AVCapturePhotoSettings (10.13+): the per-shot settings object handed to
// -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]. It is a plain value object -- the
// capture work is the output's -- so this is the whole class as of 10.13, backed by nothing.
//
// -maxPhotoDimensions is deliberately NOT implemented: it is a macOS 13 addition, and its
// counterpart -[AVCaptureDeviceFormat supportedMaxPhotoDimensions] (macOS 14) has no 10.9 equivalent
// to read the supported sizes from. Callers gate it on respondsToSelector: precisely so an older
// OS can decline, so declining is the correct answer rather than a shortfall; a stub that claimed it
// would send the caller on to ask the device format a question this OS cannot answer.
WK_PRIV_CLASS(AVCapturePhotoSettings) @interface AVCapturePhotoSettings : NSObject
+ (instancetype)photoSettings;
+ (instancetype)photoSettingsWithFormat:(NSDictionary *)format;
@property (nonatomic, readonly) NSDictionary *format;
@property (nonatomic) NSInteger flashMode;
@property (nonatomic, getter=isAutoRedEyeReductionEnabled) BOOL autoRedEyeReductionEnabled;
@end

@implementation AVCapturePhotoSettings {
    NSDictionary *_format;
    NSInteger _flashMode;
    BOOL _autoRedEyeReductionEnabled;
}

@synthesize flashMode = _flashMode;
@synthesize autoRedEyeReductionEnabled = _autoRedEyeReductionEnabled;

+ (instancetype)photoSettings
{
    return [self photoSettingsWithFormat:nil];
}

+ (instancetype)photoSettingsWithFormat:(NSDictionary *)format
{
    AVCapturePhotoSettings *settings = [[[self alloc] init] autorelease];
    if (settings)
        settings->_format = [format copy];
    return settings;
}

- (void)dealloc
{
    [_format release];
    [super dealloc];
}

- (NSDictionary *)format
{
    return _format;
}

@end
WK_PRIV_ALIAS(AVCapturePhotoSettings);
WK_POLYFILL_CLASS("AVFoundation", AVCapturePhotoSettings);

// The object handed to -captureOutput:didFinishProcessingPhoto:error:. AVCapturePhoto is absent on
// 10.9 as well, but nothing ever looks it up by name -- a caller only receives one and reads the
// encoded photo off it -- so it needs no public name and no registry entry, and stays private here.
@interface WKPolyfillCapturedPhoto : NSObject
@property (nonatomic, copy) NSData *fileDataRepresentation;
@end

@implementation WKPolyfillCapturedPhoto {
    NSData *_fileDataRepresentation;
}
@synthesize fileDataRepresentation = _fileDataRepresentation;
- (void)dealloc
{
    [_fileDataRepresentation release];
    [super dealloc];
}
@end

@protocol WKPolyfillAVCaptureStillImageOutput <NSObject>
- (id)connectionWithMediaType:(NSString *)mediaType;
- (void)captureStillImageAsynchronouslyFromConnection:(id)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler;
@end

@protocol WKPolyfillAVCaptureStillImageOutputClass <NSObject>
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)imageDataSampleBuffer;
@end

@protocol WKPolyfillAVCapturePhotoCaptureDelegate <NSObject>
- (void)captureOutput:(id)output didFinishProcessingPhoto:(id)photo error:(NSError *)error;
@end

// -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:], implemented on 10.9's
// AVCaptureStillImageOutput -- the same still-capture facility under its pre-10.15 name, which is
// why this class can subclass it and inherit -connectionWithMediaType:, session membership, and
// everything else AVCaptureOutput provides. The settings object carries the requested container
// format; JPEG is the only one 10.9's still-image path produces, and
// +jpegStillImageNSDataRepresentation: is how it hands the encoded bytes back, so the photo's
// -fileDataRepresentation is that JPEG.
static void wkCapturePhotoWithSettings(id self, SEL cmd, id settings, id delegate)
{
    (void)cmd;

    id<WKPolyfillAVCaptureStillImageOutput> output = (id<WKPolyfillAVCaptureStillImageOutput>)self;
    id<WKPolyfillAVCapturePhotoCaptureDelegate> photoDelegate = (id<WKPolyfillAVCapturePhotoCaptureDelegate>)delegate;
    Class<WKPolyfillAVCaptureStillImageOutputClass> outputClass = (Class<WKPolyfillAVCaptureStillImageOutputClass>)[self class];

    // AVVideoCodecKey, and AVVideoCodecTypeJPEG's value. Spelled out rather than read from
    // AVFoundation, for the same reason as AVMediaTypeVideo above.
    NSString *requestedCodec = [[(AVCapturePhotoSettings *)settings format] objectForKey:@"AVVideoCodecKey"];
    id connection = (!requestedCodec || [requestedCodec isEqualToString:@"jpeg"])
        ? [output connectionWithMediaType:WK_AV_MEDIA_TYPE_VIDEO] : nil;

    if (!connection) {
        // Either there is no video connection, or the caller asked for a container 10.9's
        // still-image path cannot produce (it encodes JPEG and nothing else). The real API reports a
        // capture it cannot start through the delegate's error argument rather than by doing nothing
        // -- and rather than by quietly substituting a different format -- so the caller's pending
        // request always completes, and completes truthfully.
        [photoDelegate captureOutput:self didFinishProcessingPhoto:nil
                               error:[NSError errorWithDomain:NSOSStatusErrorDomain code:-11800 userInfo:nil]];
        return;
    }

    [output captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        NSData *data = (!error && imageDataSampleBuffer) ? [outputClass jpegStillImageNSDataRepresentation:imageDataSampleBuffer] : nil;
        if (!data && !error)
            error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-11800 userInfo:nil];

        WKPolyfillCapturedPhoto *photo = nil;
        if (data) {
            photo = [[[WKPolyfillCapturedPhoto alloc] init] autorelease];
            photo.fileDataRepresentation = data;
        }
        [photoDelegate captureOutput:self didFinishProcessingPhoto:photo error:error];
    }];
}

WK_POLYFILL_CLASS_RESOLVED("AVFoundation", AVCapturePhotoOutput, wkResolveAVCapturePhotoOutput);
static void *wkResolveAVCapturePhotoOutput(void)
{
    static Class photoOutput;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class stillImageOutput = NSClassFromString(@"AVCaptureStillImageOutput");
        if (!stillImageOutput)
            return;     // AVFoundation is not in this process, so nothing can be asking for a capture
        Class cls = objc_allocateClassPair(stillImageOutput, "WKMavPolyfillPriv_AVCapturePhotoOutput", 0);
        if (!cls)
            return;
        // class_addMethod's prototype takes IMP, so the method implementation reaches it through the
        // cast the runtime's own headers require; the diagnostic stays armed everywhere else.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
        class_addMethod(cls, sel_registerName("capturePhotoWithSettings:delegate:"),
                        (IMP)wkCapturePhotoWithSettings, "v@:@@");
#pragma clang diagnostic pop
        objc_registerClassPair(cls);
        photoOutput = cls;
    });
    return photoOutput;
}

// AVSpeechSynthesizer / AVSpeechUtterance / AVSpeechSynthesisVoice (10.14+), backed by
// NSSpeechSynthesizer, which 10.9 has had since 10.3. This is the Web Speech API's synthesis engine:
// PlatformSpeechSynthesizerCocoa drives these three classes and PAL soft-links all three by name.
//
// The mapping between the two APIs is total, so the stub is a translation rather than an
// approximation: an utterance's rate, volume, pitch and voice all have NSSpeechSynthesizer
// equivalents, and its delegate callbacks (start / finish / pause / continue / cancel / word range)
// are the ones NSSpeechSynthesizerDelegate reports. AVSpeechSynthesizer speaks a queue of utterances
// where NSSpeechSynthesizer speaks one string, so the queue is kept here and drained in
// -startNext.

// The AVSpeechBoundary values the pause/stop calls take.
typedef NS_ENUM(NSInteger, WKPolyfillAVSpeechBoundary) {
    WKPolyfillAVSpeechBoundaryImmediate = 0,
    WKPolyfillAVSpeechBoundaryWord = 1,
};

@class AVSpeechSynthesisVoice;
@class AVSpeechUtterance;
@class AVSpeechSynthesizer;

// The AVSpeechSynthesizerDelegate callbacks sent to the caller's delegate. Declared informally
// because the delegate is the caller's object, conforming to the SDK's protocol, not ours.
@interface NSObject (WKPolyfillAVSpeechSynthesizerDelegate)
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didStartSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didPauseSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didContinueSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance;
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance;
@end

WK_PRIV_CLASS(AVSpeechSynthesisVoice) @interface AVSpeechSynthesisVoice : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, readonly) BOOL isSystemVoice;
+ (NSArray *)speechVoices;
+ (NSArray *)speechVoicesIncludingSuperCompact;
+ (NSString *)currentLanguageCode;
+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language;
+ (AVSpeechSynthesisVoice *)voiceWithIdentifier:(NSString *)identifier;
// The backing NSSpeechSynthesizer voice name. Not part of AVSpeechSynthesisVoice; the synthesizer
// stub below reads it to select the voice.
@property (nonatomic, copy) NSString *nsVoiceName;
@end

// NSVoiceLocaleIdentifier is e.g. "en_US"; AVSpeechSynthesisVoice.language is BCP 47, "en-US".
static NSString *wkNormalizedSpeechLanguage(NSString *locale)
{
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

- (void)dealloc
{
    [_identifier release];
    [_name release];
    [_language release];
    [_nsVoiceName release];
    [super dealloc];
}

- (BOOL)isSystemVoice
{
    return YES;
}

+ (AVSpeechSynthesisVoice *)voiceForNSVoiceName:(NSString *)nsVoiceName
{
    if (!nsVoiceName)
        return nil;
    NSDictionary *attributes = [NSSpeechSynthesizer attributesForVoice:nsVoiceName];
    if (!attributes)
        return nil;
    AVSpeechSynthesisVoice *voice = [[[AVSpeechSynthesisVoice alloc] init] autorelease];
    voice.nsVoiceName = nsVoiceName;
    voice.identifier = nsVoiceName;
    voice.name = attributes[NSVoiceName] ?: nsVoiceName;
    NSString *locale = attributes[NSVoiceLocaleIdentifier];
    voice.language = locale ? wkNormalizedSpeechLanguage(locale) : @"en-US";
    return voice;
}

+ (NSArray *)speechVoices
{
    NSMutableArray *voices = [NSMutableArray array];
    for (NSString *nsVoiceName in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoiceName];
        if (voice)
            [voices addObject:voice];
    }
    return voices;
}

// The "super compact" tier is an iOS voice-asset distinction; 10.9 ships one tier, so the two lists
// are the same list.
+ (NSArray *)speechVoicesIncludingSuperCompact
{
    return [self speechVoices];
}

+ (NSString *)currentLanguageCode
{
    AVSpeechSynthesisVoice *defaultVoice = [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];
    if (defaultVoice.language.length)
        return defaultVoice.language;
    NSString *language = [[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode];
    return language.length ? language : @"en-US";
}

+ (AVSpeechSynthesisVoice *)voiceWithLanguage:(NSString *)language
{
    if (!language.length)
        return [self voiceForNSVoiceName:[NSSpeechSynthesizer defaultVoice]];

    NSString *target = [wkNormalizedSpeechLanguage(language) lowercaseString];
    NSString *targetPrefix = [[target componentsSeparatedByString:@"-"] firstObject];
    AVSpeechSynthesisVoice *prefixMatch = nil;
    for (NSString *nsVoiceName in [NSSpeechSynthesizer availableVoices]) {
        AVSpeechSynthesisVoice *voice = [self voiceForNSVoiceName:nsVoiceName];
        NSString *voiceLanguage = [voice.language lowercaseString];
        if ([voiceLanguage isEqualToString:target])
            return voice;
        if (!prefixMatch && [[[voiceLanguage componentsSeparatedByString:@"-"] firstObject] isEqualToString:targetPrefix])
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
WK_PRIV_ALIAS(AVSpeechSynthesisVoice);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechSynthesisVoice);

WK_PRIV_CLASS(AVSpeechUtterance) @interface AVSpeechUtterance : NSObject
@property (nonatomic, copy) NSString *speechString;
@property (nonatomic) float rate;
@property (nonatomic) float volume;
@property (nonatomic) float pitchMultiplier;
@property (nonatomic, retain) AVSpeechSynthesisVoice *voice;
+ (instancetype)speechUtteranceWithString:(NSString *)string;
@end

@implementation AVSpeechUtterance {
    NSString *_speechString;
    float _rate;
    float _volume;
    float _pitchMultiplier;
    AVSpeechSynthesisVoice *_voice;
}

@synthesize speechString = _speechString;
@synthesize rate = _rate;
@synthesize volume = _volume;
@synthesize pitchMultiplier = _pitchMultiplier;
@synthesize voice = _voice;

+ (instancetype)speechUtteranceWithString:(NSString *)string
{
    AVSpeechUtterance *utterance = [[[self alloc] init] autorelease];
    if (!utterance)
        return nil;
    utterance.speechString = string;
    utterance.rate = 0.5;           // AVSpeechUtteranceDefaultSpeechRate
    utterance.volume = 1.0;
    utterance.pitchMultiplier = 1.0;
    return utterance;
}

- (void)dealloc
{
    [_speechString release];
    [_voice release];
    [super dealloc];
}

@end
WK_PRIV_ALIAS(AVSpeechUtterance);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechUtterance);

WK_PRIV_CLASS(AVSpeechSynthesizer) @interface AVSpeechSynthesizer : NSObject
@property (nonatomic, assign) id delegate;
- (void)speakUtterance:(AVSpeechUtterance *)utterance;
- (void)pauseSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary;
- (void)continueSpeaking;
- (void)stopSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary;
@end

// AVSpeechUtterance.rate is 0..1 with 0.5 the default; NSSpeechSynthesizer.rate is words per minute,
// where ~175 is the default. Map linearly onto 0..350 wpm so 0.5 lands on the NSSpeechSynthesizer
// default, and clamp to the range the engine stays intelligible over.
static float wkNSSpeechRateForAVRate(float avRate)
{
    float wordsPerMinute = avRate * 350.0f;
    if (wordsPerMinute < 80.0f)
        wordsPerMinute = 80.0f;
    if (wordsPerMinute > 400.0f)
        wordsPerMinute = 400.0f;
    return wordsPerMinute;
}

@implementation AVSpeechSynthesizer {
    NSSpeechSynthesizer *_nsSynthesizer;
    NSMutableArray *_queue;
    AVSpeechUtterance *_current;
    BOOL _stopping;
    id _delegate;
}

@synthesize delegate = _delegate;

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _nsSynthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
    _nsSynthesizer.delegate = (id)self;
    _queue = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    _nsSynthesizer.delegate = nil;
    [_nsSynthesizer release];
    [_queue release];
    [_current release];
    [super dealloc];
}

// AVSpeechUtterance.pitchMultiplier scales the voice's natural pitch (0.5 = half, 2.0 = double,
// 1.0 = unchanged). NSSpeechPitchBaseProperty is that pitch in hertz and is voice-specific, so the
// multiplier is applied to whatever the currently selected voice reports as its base -- which is why
// this runs after -setVoice:, when the property already holds the new voice's own base.
- (void)applyPitchMultiplier:(float)multiplier
{
    if (multiplier == 1.0)
        return;
    NSNumber *basePitch = [_nsSynthesizer objectForProperty:NSSpeechPitchBaseProperty error:NULL];
    if (!basePitch)
        return;
    [_nsSynthesizer setObject:@(basePitch.floatValue * multiplier) forProperty:NSSpeechPitchBaseProperty error:NULL];
}

- (void)startNext
{
    if (_current || !_queue.count)
        return;
    _current = [_queue.firstObject retain];

    if (_current.voice.nsVoiceName)
        [_nsSynthesizer setVoice:_current.voice.nsVoiceName];
    _nsSynthesizer.rate = wkNSSpeechRateForAVRate(_current.rate);
    _nsSynthesizer.volume = _current.volume;
    [self applyPitchMultiplier:_current.pitchMultiplier];

    _stopping = NO;
    if (![_nsSynthesizer startSpeakingString:_current.speechString ?: @""]) {
        // The engine declined the string. AVSpeechSynthesizer never leaves an utterance pending, so
        // report it cancelled and move on, which also drains the rest of the queue.
        AVSpeechUtterance *utterance = [_current autorelease];
        _current = nil;
        [_queue removeObject:utterance];
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];
        [self startNext];
        return;
    }

    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didStartSpeechUtterance:)])
        [_delegate speechSynthesizer:self didStartSpeechUtterance:_current];
}

- (void)speakUtterance:(AVSpeechUtterance *)utterance
{
    if (!utterance)
        return;
    [_queue addObject:utterance];
    [self startNext];
}

- (void)pauseSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary
{
    if (!_current)
        return;
    [_nsSynthesizer pauseSpeakingAtBoundary:(boundary == WKPolyfillAVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didPauseSpeechUtterance:)])
        [_delegate speechSynthesizer:self didPauseSpeechUtterance:_current];
}

- (void)continueSpeaking
{
    if (!_current)
        return;
    [_nsSynthesizer continueSpeaking];
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:didContinueSpeechUtterance:)])
        [_delegate speechSynthesizer:self didContinueSpeechUtterance:_current];
}

- (void)stopSpeakingAtBoundary:(WKPolyfillAVSpeechBoundary)boundary
{
    _stopping = YES;
    [_queue removeAllObjects];
    [_nsSynthesizer stopSpeakingAtBoundary:(boundary == WKPolyfillAVSpeechBoundaryWord ? NSSpeechWordBoundary : NSSpeechImmediateBoundary)];
    // A stop while speaking arrives as -didFinishSpeaking:NO, which delivers the cancel callback.
    // A stop while idle does not, so deliver it here.
    if (!_nsSynthesizer.isSpeaking && _current) {
        AVSpeechUtterance *utterance = [_current autorelease];
        _current = nil;
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
            [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];
    }
}

#pragma mark NSSpeechSynthesizerDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
    (void)sender;
    if (!_current)
        return;
    AVSpeechUtterance *utterance = [_current autorelease];
    _current = nil;
    [_queue removeObject:utterance];

    if (finishedSpeaking && !_stopping) {
        if ([_delegate respondsToSelector:@selector(speechSynthesizer:didFinishSpeechUtterance:)])
            [_delegate speechSynthesizer:self didFinishSpeechUtterance:utterance];
    } else if ([_delegate respondsToSelector:@selector(speechSynthesizer:didCancelSpeechUtterance:)])
        [_delegate speechSynthesizer:self didCancelSpeechUtterance:utterance];

    _stopping = NO;
    [self startNext];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender willSpeakWord:(NSRange)characterRange ofString:(NSString *)string
{
    (void)sender;
    (void)string;
    if (!_current)
        return;
    if ([_delegate respondsToSelector:@selector(speechSynthesizer:willSpeakRangeOfSpeechString:utterance:)])
        [_delegate speechSynthesizer:self willSpeakRangeOfSpeechString:characterRange utterance:_current];
}

@end
WK_PRIV_ALIAS(AVSpeechSynthesizer);
WK_POLYFILL_CLASS("AVFoundation", AVSpeechSynthesizer);

// AVOutputContext / AVOutputDevice (AVFoundation SPI, 10.11+): the wireless-playback-target ("AirPlay to
// this device") routing surface. 10.9 has no such facility at all — no route discovery, no output-device
// registry — so the honest answer to every query is the empty one, and that is exactly what these return.
//
// An empty output-device list is not a placeholder: it is what the real API reports on a machine with no
// AirPlay receivers in range, which is the permanent condition here. WebCore's wireless-playback code is
// written for that answer — it simply never offers a route picker target.
//
// These exist so ENABLE(WIRELESS_PLAYBACK_TARGET) can stay at upstream's ON, which keeps
// Source/cmake/OptionsMac.cmake and PAL/pal/PlatformMac.cmake byte-upstream. Supplying two stub classes in
// this layer is the cheaper trade: a divergence in Source/ is paid at every upstream merge, a stub here is
// paid once and is confined to WebKit's own images.
WK_PRIV_CLASS(AVOutputDevice) @interface AVOutputDevice : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *deviceName;
@property (nonatomic, readonly) NSUInteger deviceFeatures;
@end

@implementation AVOutputDevice
- (NSString *)name { return @""; }
- (NSString *)deviceName { return @""; }
// No features: this device can carry neither audio, video nor a screen, because it cannot exist.
- (NSUInteger)deviceFeatures { return 0; }
@end
WK_PRIV_ALIAS(AVOutputDevice);

WK_PRIV_CLASS(AVOutputContext) @interface AVOutputContext : NSObject <NSSecureCoding>
+ (instancetype)outputContext;
+ (instancetype)iTunesAudioContext;
+ (AVOutputContext *)sharedAudioPresentationOutputContext;
+ (AVOutputContext *)sharedSystemAudioContext;
+ (AVOutputContext *)outputContextForID:(NSString *)ID;
@property (nonatomic, readonly) NSString *deviceName;
@property (readonly) BOOL supportsMultipleOutputDevices;
@property (readonly) NSArray *outputDevices;
@property (nonatomic, readonly) AVOutputDevice *outputDevice;
@end

@implementation AVOutputContext

// The real API vends a shared context per audio presentation; with no routing service there is one
// context and it routes nowhere, so a single shared instance is the faithful shape.
+ (instancetype)outputContext { return [self sharedAudioPresentationOutputContext]; }
+ (instancetype)iTunesAudioContext { return [self sharedAudioPresentationOutputContext]; }
+ (AVOutputContext *)sharedSystemAudioContext { return [self sharedAudioPresentationOutputContext]; }

+ (AVOutputContext *)sharedAudioPresentationOutputContext
{
    static AVOutputContext *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[AVOutputContext alloc] init]; });
    return shared;
}

// No context can be looked up by ID because none is ever published.
+ (AVOutputContext *)outputContextForID:(NSString *)ID { (void)ID; return nil; }

- (NSString *)deviceName { return @""; }
- (BOOL)supportsMultipleOutputDevices { return NO; }
- (NSArray *)outputDevices { return @[]; }
- (AVOutputDevice *)outputDevice { return nil; }

// NSSecureCoding: CoreIPCAVOutputContext serialises one across the IPC boundary. A context that names no
// device carries no state, so encoding writes nothing and decoding yields the shared context.
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (instancetype)initWithCoder:(NSCoder *)coder
{
    (void)coder;
    [self release];
    return [[AVOutputContext sharedAudioPresentationOutputContext] retain];
}

@end
WK_PRIV_ALIAS(AVOutputContext);
