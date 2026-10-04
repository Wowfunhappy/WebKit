#import <Foundation/Foundation.h>

// Safari's storage for the site of the URL, from the URL's origin on either scheme and the host with and
// without "www.": its local storage, by origin, is returned, and the indexed databases the clip's store
// lacks are copied into it.
#ifdef __cplusplus
extern "C"
#endif
NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *WCTakeSafariStorageForSite(NSURL *);
