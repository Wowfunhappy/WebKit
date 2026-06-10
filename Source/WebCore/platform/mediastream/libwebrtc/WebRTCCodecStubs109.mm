/*
 * 10.9 backport: stub definitions for the H.265 (HEVC) and AV1 WebRTC video
 * codec classes.
 *
 * libwebrtc's WebKit SDK references the H.265 and AV1 encoder/decoder classes
 * unconditionally from its codec factories (RTCDefaultVideo{En,De}coderFactory),
 * but the implementing .mm files (RTCVideoEncoderH265.mm, RTCVideoDecoderH265.mm,
 * RTCVideoEncoderAV1.mm, RTCVideoDecoderAV1.mm and RTCH265ProfileLevelId.mm) are
 * excluded from the build on 10.9 — HEVC VideoToolbox is 10.13+ and AV1 is not
 * available. Without their class objects, WebCore (which force-loads libwebrtc.a)
 * fails to link / dyld aborts Safari at launch ("undefined symbol:
 * _OBJC_CLASS_$_WK_RTCVideoEncoderH265", etc.).
 *
 * These stubs satisfy the class references. They are never instantiated at
 * runtime: the factories only construct them when H.265/AV1 is requested, and
 * both are reported unsupported on 10.9 (createWebKitEncoderFactory is called
 * with supportsH265 = Off and supportsAv1 = Off — see LibWebRTCProviderCocoa).
 * So WebRTC runs with VP8 + H.264.
 */

#import "config.h"

#if ENABLE(WEB_RTC) && USE(LIBWEBRTC)

#import <Foundation/Foundation.h>

// From RTCH265ProfileLevelId.mm (excluded on 10.9).
NSString *const kRTCVideoCodecH265Name = @"H265";

__attribute__((objc_runtime_name("WK_RTCVideoEncoderH265")))
@interface RTCVideoEncoderH265 : NSObject
- (instancetype)initWithCodecInfo:(id)codecInfo;
@end
@implementation RTCVideoEncoderH265
- (instancetype)initWithCodecInfo:(id)codecInfo { return [super init]; }
@end

__attribute__((objc_runtime_name("WK_RTCVideoDecoderH265")))
@interface RTCVideoDecoderH265 : NSObject
@end
@implementation RTCVideoDecoderH265
@end

__attribute__((objc_runtime_name("WK_RTCVideoEncoderAV1")))
@interface RTCVideoEncoderAV1 : NSObject
+ (id)av1Encoder;
@end
@implementation RTCVideoEncoderAV1
+ (id)av1Encoder { return nil; }
@end

__attribute__((objc_runtime_name("WK_RTCVideoDecoderAV1")))
@interface RTCVideoDecoderAV1 : NSObject
+ (id)av1Decoder;
@end
@implementation RTCVideoDecoderAV1
+ (id)av1Decoder { return nil; }
@end

#endif // ENABLE(WEB_RTC) && USE(LIBWEBRTC)
