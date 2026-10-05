#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// The whitelist and blacklist Safari 7 gives an extension's content script or style sheet: the extension's
// lists limited to the website access its Info.plist's Permissions grant.
void WCSanitizeContentLists(NSArray *whitelist, NSArray *blacklist, NSDictionary *permissions, NSArray **sanitizedWhitelist, NSArray **sanitizedBlacklist);

// The MIME type WebKit gives a file at the path.
NSString *WCMIMETypeForPath(NSString *path);

#ifdef __cplusplus
}
#endif
