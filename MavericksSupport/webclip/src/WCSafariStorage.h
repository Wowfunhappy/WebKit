#import <Foundation/Foundation.h>

// Safari's local storage for the site of the URL, by origin: the URL's origin on either scheme, and the
// host with and without "www.".
#ifdef __cplusplus
extern "C"
#endif
NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *WCSafariLocalStorageForSite(NSURL *);
