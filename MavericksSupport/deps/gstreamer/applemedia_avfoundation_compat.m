/*
 * MAVERICKS_BACKPORT: AVFoundation compatibility shim for libgstapplemedia.dylib.
 *
 * The macOS-26-built applemedia plugin references 7 AVAudioSettings keys that 10.9's AVFoundation does
 * not export. This shim REEXPORTS the real AVFoundation (so the plugin's AVCapture* / AVAsset* classes
 * still resolve) and DEFINES the 7 missing keys. They are used by the plugin's audio asset-reader path,
 * not by avfvideosrc camera capture, so the camera works regardless of their values.
 *
 * Built by build-applemedia-compat.sh, which repoints the plugin's AVFoundation load command to
 * @rpath/libavfoundation_compat.dylib (a high -compatibility_version so dyld accepts the substitution).
 */
#import <Foundation/Foundation.h>

NSString * const AVFormatIDKey = @"AVFormatIDKey";
NSString * const AVSampleRateKey = @"AVSampleRateKey";
NSString * const AVNumberOfChannelsKey = @"AVNumberOfChannelsKey";
NSString * const AVLinearPCMBitDepthKey = @"AVLinearPCMBitDepthKey";
NSString * const AVLinearPCMIsBigEndianKey = @"AVLinearPCMIsBigEndianKey";
NSString * const AVLinearPCMIsFloatKey = @"AVLinearPCMIsFloatKey";
NSString * const AVLinearPCMIsNonInterleaved = @"AVLinearPCMIsNonInterleaved";
