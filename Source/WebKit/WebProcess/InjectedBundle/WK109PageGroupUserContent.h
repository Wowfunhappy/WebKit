/*
 * MAVERICKS_BACKPORT: page-group-scoped user content for the legacy
 * WKBundleAddUserScript/WKBundleAddUserStyleSheet C API.
 *
 * Safari 7's injected bundle (Safari.framework) injects extension CONTENT
 * SCRIPTS and style sheets by calling WKBundleAddUserScript /
 * WKBundleAddUserStyleSheet with the page group it obtained from the bundle
 * initialization user data and a script world it created with
 * WKBundleScriptWorldCreateWorld. Upstream removed the page-group-scoped
 * user content machinery (modern WebKit scopes user content per
 * WKUserContentController), so this registry restores the old semantics
 * inside the WebContent process: scripts/sheets are recorded per page-group
 * identifier (with their script world), applied immediately to every live
 * WebPage in that group, and re-applied to pages created later
 * (WebProcess::createWebPage calls wk109ApplyPageGroupUserContent).
 */

#pragma once

#include <wtf/Forward.h>

namespace WebCore {
class UserScript;
class UserStyleSheet;
}

namespace WebKit {

class InjectedBundleScriptWorld;
class WebPage;

void wk109AddUserScript(const String& pageGroupIdentifier, InjectedBundleScriptWorld&, WebCore::UserScript&&);
void wk109AddUserStyleSheet(const String& pageGroupIdentifier, InjectedBundleScriptWorld&, WebCore::UserStyleSheet&&);
void wk109RemoveUserScript(const String& pageGroupIdentifier, InjectedBundleScriptWorld&, const URL&);
void wk109RemoveUserScripts(const String& pageGroupIdentifier, InjectedBundleScriptWorld&);
void wk109RemoveUserStyleSheet(const String& pageGroupIdentifier, InjectedBundleScriptWorld&, const URL&);
void wk109RemoveUserStyleSheets(const String& pageGroupIdentifier, InjectedBundleScriptWorld&);
void wk109RemoveAllUserContent(const String& pageGroupIdentifier);

// Applies all recorded user content for the page's group to a (new) page.
void wk109ApplyPageGroupUserContent(WebPage&);

} // namespace WebKit
