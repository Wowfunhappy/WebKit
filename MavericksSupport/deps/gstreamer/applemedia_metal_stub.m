/*
 * MAVERICKS_BACKPORT: provides the one Metal class libgstapplemedia.dylib references directly,
 * MTLTextureDescriptor. The plugin links Metal.framework (absent on 10.9) for its Vulkan/Metal video
 * path; this dummy class lets the plugin's direct Metal symbol resolve so the dylib can LOAD. It is
 * never instantiated during AVFoundation camera capture.
 *
 * Built by build-applemedia-compat.sh, which repoints the plugin's Metal.framework load command to
 * @rpath/libmetal_stub.dylib.
 */
#import <Foundation/Foundation.h>

@interface MTLTextureDescriptor : NSObject
@end

@implementation MTLTextureDescriptor
@end
