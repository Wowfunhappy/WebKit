/*
 * LSCopyDefaultApplicationURLForURL (CoreServices, 10.10+) --
 * custom polyfill (not from macports-legacy-support).
 *
 * 10.9's LaunchServices lacks this entry point. Back-fill it with the 10.9-era
 * APIs: take the URL's scheme, find its default-handler bundle id, and resolve
 * that to the handler app's URL. On success return a +1 CFURLRef (the create
 * rule the real function uses); on failure return NULL *and set *outError to a
 * non-NULL CFError*.
 *
 * Setting *outError matters: callers like the Rust `webbrowser` crate, on a NULL
 * result, immediately wrap *outError as a CFError to log it -- a NULL there makes
 * core-foundation panic ("Attempted to create a NULL object"), which is what made
 * Codex's "Sign in with ChatGPT" appear to freeze. With a real error set, the
 * caller logs it and falls back cleanly; with a real app URL, it just works.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

CFURLRef LSCopyDefaultApplicationURLForURL(CFURLRef inURL, LSRolesMask inRoleMask, CFErrorRef *outError) {
	(void)inRoleMask;
	OSStatus st = kLSApplicationNotFoundErr;
	CFURLRef appURL = NULL;

	CFStringRef scheme = inURL ? CFURLCopyScheme(inURL) : NULL;
	if (scheme) {
		CFStringRef bundleID = LSCopyDefaultHandlerForURLScheme(scheme);
		if (bundleID) {
			st = LSFindApplicationForInfo(kLSUnknownCreator, bundleID, NULL, NULL, &appURL);
			CFRelease(bundleID);
		}
		CFRelease(scheme);
	}

	if (st != noErr || !appURL) {
		if (appURL) { CFRelease(appURL); appURL = NULL; }
		if (outError) {
			*outError = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, st, NULL);
		}
		return NULL;
	}
	return appURL;
}
