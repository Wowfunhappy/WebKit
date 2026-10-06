// The clip's copy of Safari 7 extensions in its web content process, as Safari's injected bundle gives its
// tabs theirs: the content world the plug-in puts an extension's content scripts and style sheets in, named
// after the extension's root (safari-extension://<key>/<token>/), gets Safari 7's content API
// (`safari.self`, its tab proxy and `safari.extension.baseURI`), whose messages the plug-in carries to and
// from the extension's pages.

#pragma once

#include <WebKit/WKBase.h>
#include <WebKit/WKBundlePage.h>

namespace WebClip {

void initializeExtensions(WKBundleRef);
// Whether the message was the extensions'.
bool extensionsDidReceiveMessageToPage(WKBundlePageRef, WKStringRef name, WKTypeRef body);
void extensionsDidClearWindowObjectForFrame(WKBundlePageRef, WKBundleFrameRef, WKBundleScriptWorldRef);
void extensionsDidRemoveFrameFromHierarchy(WKBundleFrameRef);
void extensionsWillDestroyPage(WKBundlePageRef);

} // namespace WebClip
