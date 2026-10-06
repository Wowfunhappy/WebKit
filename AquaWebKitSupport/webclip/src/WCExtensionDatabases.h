#import <Foundation/Foundation.h>

// The Web SQL databases of a Safari extension's pages, which WebCore's database tracker records by origin:
// Safari's, in Safari's database directory, become the databases of the origin the extension has in a clip,
// in the directory of the process's WebKit 1 pages.
#ifdef __cplusplus
extern "C"
#endif
BOOL WCCopyExtensionWebSQLDatabases(NSString *safariDatabaseDirectory, NSString *origin, NSString *clipOrigin);

#ifdef __cplusplus
extern "C"
#endif
void WCRemoveExtensionWebSQLDatabases(NSString *clipOrigin);
