// declarativeNetRequest for one Safari 7 extension, on WebKit's WebExtension implementation of it: the rule
// validator and translator, the dynamic and session rule stores, and content rule lists. Its static rulesets are
// its Info.plist's `declarative_net_request` entry, read as a WebExtension manifest's; its dynamic rules persist
// in its storage directory, and its session rules last while it is loaded. The rules compile into one content
// rule list, named by the extension key, that every page's user content controller holds. Each method follows
// the WebExtensionContext method of the same name.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/JSONValues.h>
#include <wtf/RefCounted.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

OBJC_CLASS NSMutableDictionary;

namespace WebKit {

class WebExtension;
class WebExtensionDeclarativeNetRequestSQLiteStore;
class WebPageProxy;
class WebUserContentControllerProxy;

class LegacyExtensionDeclarativeNetRequest : public RefCounted<LegacyExtensionDeclarativeNetRequest>, public CanMakeWeakPtr<LegacyExtensionDeclarativeNetRequest> {
public:
    // `root` is safari-extension://<key>/<token>/, which extensionPath redirects resolve against.
    static Ref<LegacyExtensionDeclarativeNetRequest> create(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess&);
    ~LegacyExtensionDeclarativeNetRequest();

    const String& extensionKey() const { return m_extensionKey; }
    const URL& root() const { return m_root; }
    // The URLs redirect and modifyHeaders rules act on: the extension's website access.
    const Vector<String>& actionPatterns() const { return m_actionPatterns; }

    void load();
    void unload();
    void addDeclarativeNetRequestRules(WebUserContentControllerProxy&);

    // A `browser.declarativeNetRequest` method an extension page calls (`method` without the namespace), with
    // its one argument, as WebExtensionAPIDeclarativeNetRequest validates and answers it. Calls wait for the
    // extension's rules to load.
    using CallResult = Expected<RefPtr<JSON::Value>, String>;
    void performCall(const String& method, RefPtr<JSON::Value>&& argument, Function<bool(double tabID)>&& tabExists, CompletionHandler<void(CallResult&&)>&&);
    // Called with a tab's action count whenever it changes while the extension displays it.
    void setActionCountObserver(Function<void(double tabID, double count)>&& observer) { m_actionCountObserver = WTF::move(observer); }

    using Error = String;
    void declarativeNetRequestGetEnabledRulesets(CompletionHandler<void(Vector<String>&&)>&&);
    void declarativeNetRequestUpdateEnabledRulesets(const Vector<String>& rulesetIdentifiersToEnable, const Vector<String>& rulesetIdentifiersToDisable, CompletionHandler<void(Expected<void, Error>&&)>&&);
    void declarativeNetRequestGetDynamicRules(Vector<double>&& filter, CompletionHandler<void(Expected<String, Error>&&)>&&);
    void declarativeNetRequestUpdateDynamicRules(String&& rulesToAddJSON, Vector<double>&& ruleIDsToDelete, CompletionHandler<void(Expected<void, Error>&&)>&&);
    void declarativeNetRequestGetSessionRules(Vector<double>&& filter, CompletionHandler<void(Expected<String, Error>&&)>&&);
    void declarativeNetRequestUpdateSessionRules(String&& rulesToAddJSON, Vector<double>&& ruleIDsToDelete, CompletionHandler<void(Expected<void, Error>&&)>&&);
    void declarativeNetRequestDisplayActionCountAsBadgeText(bool);
    void declarativeNetRequestIncrementActionCount(double tabID, double increment);
    bool displaysActionCount() const;
    // The tab's action count, or nullopt when the extension does not display it.
    std::optional<double> actionCountForTab(double tabID) const;
    // A main-frame commit starts the tab's count over.
    void resetActionCount(double tabID);
    // Of `pages`, the one shown in the frontmost window that shows one: Safari 7's activeBrowserWindow's
    // activeTab, whether or not Safari is the active application.
    static RefPtr<WebPageProxy> activeTabOfFrontmostWindow(const Vector<Ref<WebPageProxy>>& pages);
    Ref<JSON::Array> declarativeNetRequestGetMatchedRules(std::optional<double> tabID, std::optional<WallTime> minTimeStamp);

    // A load in the tab matched the extension's rules.
    void handleContentRuleListNotificationForTab(double tabID, const URL&);
    void tabWasRemoved(double tabID);

private:
    LegacyExtensionDeclarativeNetRequest(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&&, const LegacyExtensions::WebsiteAccess&);

    struct MatchedRule {
        URL url;
        WallTime timeStamp;
        double tabID;
    };

    String storageDirectory() const;
    String declarativeNetRequestContentRuleListFilePath() const;
    void readStateFromStorage();
    void writeStateToStorage();
    void loadDeclarativeNetRequestRulesetStateFromStorage();
    void saveDeclarativeNetRequestRulesetStateToStorage(NSMutableDictionary *);
    void declarativeNetRequestToggleRulesets(const Vector<String>&, bool newValue, NSMutableDictionary *);
    std::optional<Error> declarativeNetRequestValidateRulesetIdentifiers(const Vector<String>&, const String& apiName);
    Ref<WebExtensionDeclarativeNetRequestSQLiteStore> declarativeNetRequestDynamicRulesStore();
    Ref<WebExtensionDeclarativeNetRequestSQLiteStore> declarativeNetRequestSessionRulesStore();
    void updateDeclarativeNetRequestRulesInStorage(Ref<WebExtensionDeclarativeNetRequestSQLiteStore>&&, const String& storageType, const String& apiName, Ref<JSON::Array>&& rulesToAdd, Vector<double>&& ruleIDsToRemove, CompletionHandler<void(Expected<void, Error>&&)>&&);
    void loadDeclarativeNetRequestRules(CompletionHandler<void(bool)>&&);
    void compileDeclarativeNetRequestRules(NSMutableDictionary *rulesData, CompletionHandler<void(bool)>&&);
    void removeDeclarativeNetRequestRules();
    void purgeMatchedRulesFromBefore(WallTime);
    void purgeOldMatchedRules();

    String m_extensionKey;
    URL m_root;
    LegacyExtensions::WebsiteAccess m_websiteAccess;
    RefPtr<JSON::Object> m_declarativeNetRequestEntry;
    Vector<String> m_actionPatterns;
    RefPtr<WebExtension> m_extension;
    bool m_isLoaded { false };
    RetainPtr<NSMutableDictionary> m_state;
    HashSet<String> m_enabledStaticRulesetIDs;
    HashSet<double> m_dynamicRulesIDs;
    HashSet<double> m_sessionRulesIDs;
    RefPtr<WebExtensionDeclarativeNetRequestSQLiteStore> m_dynamicRulesStore;
    RefPtr<WebExtensionDeclarativeNetRequestSQLiteStore> m_sessionRulesStore;
    Vector<MatchedRule> m_matchedRules;
    std::unique_ptr<RunLoop::Timer> m_purgeMatchedRulesTimer;
    HashMap<double, double> m_actionCounts;
    Function<void(double, double)> m_actionCountObserver;
    bool m_hasLoadedRules { false };
    Vector<Function<void()>> m_callsWaitingForRules;
};

} // namespace WebKit
