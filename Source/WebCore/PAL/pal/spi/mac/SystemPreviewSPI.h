// MAVERICKS_BACKPORT: SystemPreview/USDZ not available. Stubbed.
#pragma once
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport

#include <wtf/Compiler.h>
#include <wtf/Platform.h>

DECLARE_SYSTEM_HEADER

// FIXME: Remove the `__has_feature(modules)` condition when possible.
#if USE(APPLE_INTERNAL_SDK) && !__has_feature(modules)

#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)
#import <AssetViewer/ASVInlinePreview.h>
#endif

#else // USE(APPLE_INTERNAL_SDK)

#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)

#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@class ASVInlinePreview;
@class CAFenceHandle;

@interface ASVInlinePreview : NSObject
@property (nonatomic, readonly) NSUUID *uuid;
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly) uint32_t contextId;

- (instancetype)initWithFrame:(CGRect)frame;
- (instancetype)initWithFrame:(CGRect)frame UUID:(NSUUID *)uuid;
- (void)setupRemoteConnectionWithCompletionHandler:(void (^)(NSError * _Nullable error))handler;
- (void)preparePreviewOfFileAtURL:(NSURL *)url completionHandler:(void (^)(NSError * _Nullable error))handler;
- (void)setRemoteContext:(uint32_t)contextId;

- (void)updateFrame:(CGRect)newFrame completionHandler:(void (^)(CAFenceHandle * _Nullable fenceHandle, NSError * _Nullable error))handler;
- (void)setFrameWithinFencedTransaction:(CGRect)frame;

- (void)mouseDownAtLocation:(CGPoint)location timestamp:(NSTimeInterval)timestamp;
- (void)mouseDraggedAtLocation:(CGPoint)location timestamp:(NSTimeInterval)timestamp;
- (void)mouseUpAtLocation:(CGPoint)location timestamp:(NSTimeInterval)timestamp;

typedef void (^ASVCameraTransformReplyBlock) (simd_float3 cameraTransform, NSError * _Nullable error);
- (void)getCameraTransform:(ASVCameraTransformReplyBlock)reply;
- (void)setCameraTransform:(simd_float3)transform;

@property (nonatomic, readwrite) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readwrite) BOOL isLooping;
@property (nonatomic, readonly) BOOL isPlaying;
typedef void (^ASVSetIsPlayingReplyBlock) (BOOL isPlaying, NSError * _Nullable error);
- (void)setIsPlaying:(BOOL)isPlaying reply:(ASVSetIsPlayingReplyBlock)reply;

@property (nonatomic, readonly) BOOL hasAudio;
@property (nonatomic, readwrite) BOOL isMuted;

@end

NS_ASSUME_NONNULL_END

#endif // ENABLE(ARKIT_INLINE_PREVIEW_MAC)

#endif // USE(APPLE_INTERNAL_SDK)
MAVERICKS_BACKPORT */
