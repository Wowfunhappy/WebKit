/*
 * 10.9 backport: page-group-scoped user content for the legacy
 * WKBundleAddUserScript/WKBundleAddUserStyleSheet C API.
 * See WK109PageGroupUserContent.h.
 */

#include "config.h"
#include "WK109PageGroupUserContent.h"

#include "InjectedBundleScriptWorld.h"
#include "WebPage.h"
#include "WebPageGroupProxy.h"
#include "WebProcess.h"
#include "WebUserContentController.h"
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <wtf/HashMap.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Vector.h>
#include <asl.h>
#include <wtf/text/StringHash.h>
#include <wtf/text/WTFString.h>

// Temporary bring-up logging (mirrors the MSE_BISECT pattern); remove once
// extension content-script injection is verified end-to-end.
#define WK109_LOG(fmt, ...) asl_log(nullptr, nullptr, ASL_LEVEL_NOTICE, "WK109_USERCONTENT " fmt, ##__VA_ARGS__)

namespace WebKit {

struct WK109GroupUserContent {
    Vector<std::pair<Ref<InjectedBundleScriptWorld>, WebCore::UserScript>> scripts;
    Vector<std::pair<Ref<InjectedBundleScriptWorld>, WebCore::UserStyleSheet>> styleSheets;
};

static HashMap<String, WK109GroupUserContent>& wk109UserContentRegistry()
{
    static NeverDestroyed<HashMap<String, WK109GroupUserContent>> registry;
    return registry;
}

static void wk109ForEachPageInGroup(const String& pageGroupIdentifier, NOESCAPE const Function<void(WebPage&)>& apply)
{
    WebProcess::singleton().forEachWebPage([&](WebPage& page) {
        if (page.pageGroup().identifier() == pageGroupIdentifier)
            apply(page);
    });
}

void wk109AddUserScript(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world, WebCore::UserScript&& userScript)
{
    WK109_LOG("addUserScript group='%s' url='%s' sourceLen=%u", pageGroupIdentifier.utf8().data(), userScript.url().string().utf8().data(), (unsigned)userScript.source().length());
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().addUserScript(world, WebCore::UserScript { userScript });
    });
    auto& group = wk109UserContentRegistry().add(pageGroupIdentifier, WK109GroupUserContent { }).iterator->value;
    group.scripts.append({ Ref { world }, WTF::move(userScript) });
}

void wk109AddUserStyleSheet(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world, WebCore::UserStyleSheet&& userStyleSheet)
{
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().addUserStyleSheet(world, WebCore::UserStyleSheet { userStyleSheet });
    });
    auto& group = wk109UserContentRegistry().add(pageGroupIdentifier, WK109GroupUserContent { }).iterator->value;
    group.styleSheets.append({ Ref { world }, WTF::move(userStyleSheet) });
}

void wk109RemoveUserScript(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world, const URL& url)
{
    auto it = wk109UserContentRegistry().find(pageGroupIdentifier);
    if (it != wk109UserContentRegistry().end()) {
        it->value.scripts.removeAllMatching([&](auto& entry) {
            return entry.first.ptr() == &world && entry.second.url() == url;
        });
    }
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().removeUserScriptWithURL(world, url);
    });
}

void wk109RemoveUserScripts(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world)
{
    auto it = wk109UserContentRegistry().find(pageGroupIdentifier);
    if (it != wk109UserContentRegistry().end()) {
        it->value.scripts.removeAllMatching([&](auto& entry) {
            return entry.first.ptr() == &world;
        });
    }
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().removeUserScripts(world);
    });
}

void wk109RemoveUserStyleSheet(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world, const URL& url)
{
    auto it = wk109UserContentRegistry().find(pageGroupIdentifier);
    if (it != wk109UserContentRegistry().end()) {
        it->value.styleSheets.removeAllMatching([&](auto& entry) {
            return entry.first.ptr() == &world && entry.second.url() == url;
        });
    }
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().removeUserStyleSheetWithURL(world, url);
    });
}

void wk109RemoveUserStyleSheets(const String& pageGroupIdentifier, InjectedBundleScriptWorld& world)
{
    auto it = wk109UserContentRegistry().find(pageGroupIdentifier);
    if (it != wk109UserContentRegistry().end()) {
        it->value.styleSheets.removeAllMatching([&](auto& entry) {
            return entry.first.ptr() == &world;
        });
    }
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().removeUserStyleSheets(world);
    });
}

void wk109RemoveAllUserContent(const String& pageGroupIdentifier)
{
    wk109UserContentRegistry().remove(pageGroupIdentifier);
    wk109ForEachPageInGroup(pageGroupIdentifier, [&](WebPage& page) {
        page.userContentController().removeAllUserContent();
    });
}

void wk109ApplyPageGroupUserContent(WebPage& page)
{
    auto it = wk109UserContentRegistry().find(page.pageGroup().identifier());
    WK109_LOG("applyToPage group='%s' found=%d scripts=%u", page.pageGroup().identifier().utf8().data(), it != wk109UserContentRegistry().end(), it != wk109UserContentRegistry().end() ? (unsigned)it->value.scripts.size() : 0);
    if (it == wk109UserContentRegistry().end())
        return;
    Ref userContentController = page.userContentController();
    for (auto& entry : it->value.scripts)
        userContentController->addUserScript(entry.first, WebCore::UserScript { entry.second });
    for (auto& entry : it->value.styleSheets)
        userContentController->addUserStyleSheet(entry.first, WebCore::UserStyleSheet { entry.second });
}

} // namespace WebKit
