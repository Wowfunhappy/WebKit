// 10.9 backport stub. AVCapturePhotoOutput / AVCapturePhotoSettings / AVCapturePhoto are macOS 10.12+;
// the 10.9 SDK has no AVFoundation/AVCapturePhotoOutput.h. WebKit's photo-capture (ImageCapture /
// MediaStreamTrack.takePhoto) code references these classes but obtains them by PAL soft-linking, which
// returns nil at runtime on 10.9. This stub declares just enough of the interface for that code to
// COMPILE; at runtime the classes are absent, so AVVideoCaptureSource::photoOutput() yields nil and
// takePhoto() rejects gracefully. Camera streaming (the primary getUserMedia path) does not use these.
#pragma once

#import <AVFoundation/AVCaptureOutput.h>

@class AVCapturePhoto;
@class AVCapturePhotoOutput;

@protocol AVCapturePhotoCaptureDelegate <NSObject>
@optional
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error;
@end

@interface AVCapturePhotoSettings : NSObject
+ (instancetype)photoSettingsWithFormat:(NSDictionary<NSString *, id> *)format;
@end

@interface AVCapturePhoto : NSObject
- (NSData *)fileDataRepresentation;
@end

@interface AVCapturePhotoOutput : AVCaptureOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate;
@end
