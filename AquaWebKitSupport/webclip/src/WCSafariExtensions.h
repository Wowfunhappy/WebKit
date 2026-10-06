#import <Foundation/Foundation.h>

// A clip's copy of Safari's extensions: the installed extensions Safari runs, with their settings and
// the local storage and databases of their pages, as Safari has them when the clip is made. The
// clip's extensions run from the copy for the clip's whole life (WCExtensionRuntime.h):
//   Extensions.plist   an array of { Key: the extension's key in Safari }, in Safari's order
//   Extensions/<key>/  the extension's files
//   Settings.plist     { <key>: { Settings: { <name>: <JSON text> } } }; a clip has no secure settings
// and the local storage and Web SQL and indexed databases of the extensions' pages, under the origins the
// extensions have in the clip, where the process's WebKit 1 pages keep theirs.
// Returns whether the copy is complete; an incomplete copy is removed.
BOOL WCCopySafariExtensions(NSString *directory, NSString *clipIdentifier);

// Removes the clip's copy, with its databases.
void WCRemoveSafariExtensions(NSString *directory, NSString *clipIdentifier);
