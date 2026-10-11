#import "config.h"
#import "LegacyExtensionDeclarativeNetRequest.h"

#import "APIContentRuleList.h"
#import "APIContentRuleListStore.h"
#import "APIData.h"
#import "CocoaHelpers.h"
#import "LegacyExtensionHost.h"
#import "Logging.h"
#import "WebExtension.h"
#import "WebExtensionConstants.h"
#import "WebExtensionContext.h"
#import "WebExtensionControllerConfiguration.h"
#import "WebExtensionDeclarativeNetRequestSQLiteStore.h"
#import "WebExtensionUtilities.h"
#import "WebExtensionAPIKeys.h"
#import "WebUserContentControllerProxy.h"
#import "WKContentRuleListInternal.h"
#import "WebPageProxy.h"
#import "_WKWebExtensionDeclarativeNetRequestRule.h"
#import "_WKWebExtensionDeclarativeNetRequestTranslator.h"
#import <AppKit/AppKit.h>
#import <wtf/BlockPtr.h>
#import <wtf/FileSystem.h>
#import <wtf/RunLoop.h>
#import <wtf/SHA1.h>
#import <wtf/ThreadSafeRefCounted.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/darwin/DispatchExtras.h>
#import <wtf/text/MakeString.h>

namespace WebKit {

// The WebExtensionContext values: its translator version, state keys and matched-rule lifetime.
static constexpr size_t currentDeclarativeNetRequestRuleTranslatorVersion = 6;
static NSString * const lastLoadedDeclarativeNetRequestHashStateKey = @"LastLoadedDeclarativeNetRequestHash";
static NSString * const declarativeNetRequestRulesetStateKey = @"DeclarativeNetRequestRulesetState";
static NSString * const displayBlockedResourceCountAsBadgeTextStateKey = @"DisplayBlockedResourceCountAsBadgeText";
static constexpr Seconds purgeMatchedRulesInterval = 5_min;

Ref<LegacyExtensionDeclarativeNetRequest> LegacyExtensionDeclarativeNetRequest::create(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess& websiteAccess)
{
    return adoptRef(*new LegacyExtensionDeclarativeNetRequest(extensionKey, root, WTF::move(declarativeNetRequestEntry), websiteAccess));
}

LegacyExtensionDeclarativeNetRequest::LegacyExtensionDeclarativeNetRequest(const String& extensionKey, const URL& root, RefPtr<JSON::Object>&& declarativeNetRequestEntry, const LegacyExtensions::WebsiteAccess& websiteAccess)
    : m_extensionKey(extensionKey)
    , m_root(root)
    , m_websiteAccess(websiteAccess)
    , m_declarativeNetRequestEntry(WTF::move(declarativeNetRequestEntry))
    , m_actionPatterns(websiteAccess.urlPatterns())
{
}

LegacyExtensionDeclarativeNetRequest::~LegacyExtensionDeclarativeNetRequest() = default;

String LegacyExtensionDeclarativeNetRequest::storageDirectory() const
{
    return FileSystem::pathByAppendingComponent(WebExtensionControllerConfiguration::createDefault()->storageDirectory(), m_extensionKey);
}

String LegacyExtensionDeclarativeNetRequest::declarativeNetRequestContentRuleListFilePath() const
{
    return FileSystem::pathByAppendingComponent(storageDirectory(), "DeclarativeNetRequestContentRuleList.data"_s);
}

void LegacyExtensionDeclarativeNetRequest::readStateFromStorage()
{
    m_state = WebExtensionContext::readStateFromPath(FileSystem::pathByAppendingComponent(storageDirectory(), WebExtensionContext::plistFileName()));
}

void LegacyExtensionDeclarativeNetRequest::writeStateToStorage()
{
    FileSystem::makeAllDirectories(storageDirectory());
    RetainPtr url = adoptNS([[NSURL alloc] initFileURLWithPath:FileSystem::pathByAppendingComponent(storageDirectory(), WebExtensionContext::plistFileName()).createNSString().get()]);
    NSError *error = nil;
    if (![m_state writeToURL:url.get() error:&error])
        RELEASE_LOG_ERROR(Extensions, "Unable to save extension state: %{public}@", privacyPreservingDescription(error));
}

// The extension's static rulesets are a WebExtension's: its `declarative_net_request` entry as the manifest
// key, and the ruleset files from its root.
void LegacyExtensionDeclarativeNetRequest::load()
{
    m_isLoaded = true;
    readStateFromStorage();

    Vector<String> paths;
    if (RefPtr rulesets = m_declarativeNetRequestEntry ? m_declarativeNetRequestEntry->getArray("rule_resources"_s) : nullptr) {
        for (auto& value : *rulesets) {
            if (RefPtr ruleset = value->asObject(); ruleset && !ruleset->getString("path"_s).isEmpty())
                paths.append(ruleset->getString("path"_s));
        }
    }

    auto didLoadResources = [protectedThis = Ref { *this }](WebExtension::Resources&& resources) {
        if (!protectedThis->m_isLoaded)
            return;
        auto manifest = JSON::Object::create();
        manifest->setInteger("manifest_version"_s, 3);
        manifest->setString("name"_s, protectedThis->m_extensionKey);
        manifest->setString("version"_s, "1"_s);
        auto permissions = JSON::Array::create();
        permissions->pushString("declarativeNetRequest"_s);
        manifest->setArray("permissions"_s, WTF::move(permissions));
        if (protectedThis->m_declarativeNetRequestEntry)
            manifest->setObject("declarative_net_request"_s, *protectedThis->m_declarativeNetRequestEntry);
        resources.set("manifest.json"_s, manifest->toJSONString());
        protectedThis->m_extension = WebExtension::create(WTF::move(resources));
        protectedThis->loadDeclarativeNetRequestRulesetStateFromStorage();
        protectedThis->loadDeclarativeNetRequestRules([protectedThis](bool) {
            if (!protectedThis->m_isLoaded)
                return;
            protectedThis->m_hasLoadedRules = true;
            for (auto& call : std::exchange(protectedThis->m_callsWaitingForRules, { }))
                call();
        });
    };
    if (paths.isEmpty())
        return didLoadResources({ });

    // The session calls back on its own queue, so the shared state is reached only on the main thread.
    struct RulesetFiles : ThreadSafeRefCounted<RulesetFiles, WTF::DestructionThread::Main> {
        RulesetFiles(Vector<String>&& paths, Function<void(WebExtension::Resources&&)>&& completion)
            : paths(WTF::move(paths))
            , remaining(this->paths.size())
            , completion(WTF::move(completion))
        {
        }
        Vector<String> paths;
        size_t remaining;
        WebExtension::Resources resources;
        Function<void(WebExtension::Resources&&)> completion;
    };
    Ref files = adoptRef(*new RulesetFiles(WTF::move(paths), WTF::move(didLoadResources)));
    for (size_t index = 0; index < files->paths.size(); ++index) {
        RetainPtr request = [NSURLRequest requestWithURL:URL(m_root, files->paths[index]).createNSURL().get()];
        RetainPtr task = [NSURLSession.sharedSession dataTaskWithRequest:request.get() completionHandler:makeBlockPtr([files, index](NSData *data, NSURLResponse *, NSError *) {
            RunLoop::mainSingleton().dispatch([files, index, data = RetainPtr { data }] {
                if (data)
                    files->resources.set(files->paths[index], API::Data::create(span(data.get())));
                if (!--files->remaining)
                    files->completion(WTF::move(files->resources));
            });
        }).get()];
        [task resume];
    }
}

void LegacyExtensionDeclarativeNetRequest::unload()
{
    removeDeclarativeNetRequestRules();
    m_isLoaded = false;
    m_sessionRulesIDs.clear();
    m_dynamicRulesIDs.clear();
    m_matchedRules.clear();
    m_enabledStaticRulesetIDs.clear();
    m_actionCounts.clear();
    m_purgeMatchedRulesTimer = nullptr;
    m_hasLoadedRules = false;
    m_callsWaitingForRules.clear();
    m_dynamicRulesStore = nullptr;
    m_sessionRulesStore = nullptr;
}

// MARK: Rulesets

void LegacyExtensionDeclarativeNetRequest::loadDeclarativeNetRequestRulesetStateFromStorage()
{
    m_enabledStaticRulesetIDs.clear();

    // The saved state holds the rulesets updateEnabledRulesets changed; the rest keep their declared state.
    RefPtr extension = m_extension;
    for (auto& ruleset : extension->declarativeNetRequestRulesets()) {
        if (ruleset.enabled)
            m_enabledStaticRulesetIDs.add(ruleset.rulesetID);
    }

    auto *savedRulesetState = objectForKey<NSDictionary>(m_state.get(), declarativeNetRequestRulesetStateKey);
    for (NSString *savedIdentifier in savedRulesetState) {
        if (!extension->declarativeNetRequestRuleset(savedIdentifier))
            continue;
        if (objectForKey<NSNumber>(savedRulesetState, savedIdentifier).boolValue)
            m_enabledStaticRulesetIDs.add(savedIdentifier);
        else
            m_enabledStaticRulesetIDs.remove(savedIdentifier);
    }
}

void LegacyExtensionDeclarativeNetRequest::saveDeclarativeNetRequestRulesetStateToStorage(NSMutableDictionary *rulesetState)
{
    NSDictionary *savedRulesetState = objectForKey<NSDictionary>(m_state.get(), declarativeNetRequestRulesetStateKey);
    RetainPtr<NSMutableDictionary> updatedRulesetState;
    if (savedRulesetState)
        updatedRulesetState = adoptNS([savedRulesetState mutableCopy]);
    else
        updatedRulesetState = adoptNS([[NSMutableDictionary alloc] init]);
    [updatedRulesetState addEntriesFromDictionary:rulesetState];
    [m_state setObject:adoptNS([updatedRulesetState copy]).get() forKey:declarativeNetRequestRulesetStateKey];
    writeStateToStorage();
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestToggleRulesets(const Vector<String>& rulesetIdentifiers, bool newValue, NSMutableDictionary *rulesetIdentifiersToEnabledState)
{
    RefPtr extension = m_extension;
    for (auto& identifier : rulesetIdentifiers) {
        if (!extension->declarativeNetRequestRuleset(identifier))
            continue;
        if (newValue)
            m_enabledStaticRulesetIDs.add(identifier);
        else
            m_enabledStaticRulesetIDs.remove(identifier);
        [rulesetIdentifiersToEnabledState setObject:@(newValue) forKey:identifier.createNSString().get()];
    }
}

std::optional<LegacyExtensionDeclarativeNetRequest::Error> LegacyExtensionDeclarativeNetRequest::declarativeNetRequestValidateRulesetIdentifiers(const Vector<String>& rulesetIdentifiers, const String& apiName)
{
    for (auto& identifier : rulesetIdentifiers) {
        if (!m_extension || !m_extension->declarativeNetRequestRuleset(identifier))
            return toErrorString(apiName, nullString(), makeString("Failed to apply rules. Invalid ruleset id: "_s, identifier, "."_s));
    }
    return std::nullopt;
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestGetEnabledRulesets(CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    completionHandler(copyToVector(m_enabledStaticRulesetIDs));
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestUpdateEnabledRulesets(const Vector<String>& rulesetIdentifiersToEnable, const Vector<String>& rulesetIdentifiersToDisable, CompletionHandler<void(Expected<void, Error>&&)>&& completionHandler)
{
    static constexpr auto apiName = "declarativeNetRequest.updateEnabledRulesets()"_s;
    if (rulesetIdentifiersToEnable.isEmpty() && rulesetIdentifiersToDisable.isEmpty())
        return completionHandler({ });

    if (auto error = declarativeNetRequestValidateRulesetIdentifiers(rulesetIdentifiersToEnable, apiName))
        return completionHandler(makeUnexpected(*error));
    if (auto error = declarativeNetRequestValidateRulesetIdentifiers(rulesetIdentifiersToDisable, apiName))
        return completionHandler(makeUnexpected(*error));

    if (m_enabledStaticRulesetIDs.size() - rulesetIdentifiersToDisable.size() + rulesetIdentifiersToEnable.size() > webExtensionDeclarativeNetRequestMaximumNumberOfEnabledRulesets)
        return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), makeString("The number of enabled static rulesets exceeds the limit. Only "_s, webExtensionDeclarativeNetRequestMaximumNumberOfEnabledRulesets, " rulesets can be enabled at once."_s))));

    RetainPtr rulesetIdentifiersToEnabledState = adoptNS([[NSMutableDictionary alloc] init]);
    declarativeNetRequestToggleRulesets(rulesetIdentifiersToDisable, false, rulesetIdentifiersToEnabledState.get());
    declarativeNetRequestToggleRulesets(rulesetIdentifiersToEnable, true, rulesetIdentifiersToEnabledState.get());

    loadDeclarativeNetRequestRules([this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), rulesetIdentifiersToEnable, rulesetIdentifiersToDisable, rulesetIdentifiersToEnabledState](bool success) mutable {
        if (success) {
            saveDeclarativeNetRequestRulesetStateToStorage(rulesetIdentifiersToEnabledState.get());
            return completionHandler({ });
        }
        declarativeNetRequestToggleRulesets(rulesetIdentifiersToDisable, true, rulesetIdentifiersToEnabledState.get());
        declarativeNetRequestToggleRulesets(rulesetIdentifiersToEnable, false, rulesetIdentifiersToEnabledState.get());
        completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "Failed to apply rules."_s)));
    });
}

// MARK: Dynamic and session rules

Ref<WebExtensionDeclarativeNetRequestSQLiteStore> LegacyExtensionDeclarativeNetRequest::declarativeNetRequestDynamicRulesStore()
{
    if (!m_dynamicRulesStore)
        m_dynamicRulesStore = WebExtensionDeclarativeNetRequestSQLiteStore::create(m_extensionKey, WebExtensionDeclarativeNetRequestStorageType::Dynamic, storageDirectory(), WebExtensionDeclarativeNetRequestSQLiteStore::UsesInMemoryDatabase::No);
    return *m_dynamicRulesStore;
}

Ref<WebExtensionDeclarativeNetRequestSQLiteStore> LegacyExtensionDeclarativeNetRequest::declarativeNetRequestSessionRulesStore()
{
    if (!m_sessionRulesStore)
        m_sessionRulesStore = WebExtensionDeclarativeNetRequestSQLiteStore::create(m_extensionKey, WebExtensionDeclarativeNetRequestStorageType::Session, storageDirectory(), WebExtensionDeclarativeNetRequestSQLiteStore::UsesInMemoryDatabase::Yes);
    return *m_sessionRulesStore;
}

void LegacyExtensionDeclarativeNetRequest::updateDeclarativeNetRequestRulesInStorage(Ref<WebExtensionDeclarativeNetRequestSQLiteStore>&& storage, const String& storageType, const String& apiName, Ref<JSON::Array>&& rulesToAdd, Vector<double>&& ruleIDsToRemove, CompletionHandler<void(Expected<void, Error>&&)>&& completionHandler)
{
    storage->createSavepoint([this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storage, storageType, apiName, rulesToAdd = WTF::move(rulesToAdd), ruleIDsToRemove = WTF::move(ruleIDsToRemove)](Markable<WTF::UUID> savepointIdentifier, const String& errorMessage) mutable {
        if (!savepointIdentifier || !errorMessage.isEmpty()) {
            RELEASE_LOG_ERROR(Extensions, "Unable to create %s rules savepoint for extension %s. Error: %s", storageType.utf8().data(), m_extensionKey.utf8().data(), errorMessage.utf8().data());
            return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), errorMessage)));
        }

        storage->updateRulesByRemovingIDs(ruleIDsToRemove, rulesToAdd, [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storage, storageType, apiName, savepointIdentifier = WTF::move(savepointIdentifier)](const String& errorMessage) mutable {
            if (!errorMessage.isEmpty()) {
                RELEASE_LOG_ERROR(Extensions, "Unable to update %s rules for extension %s. Error: %s", storageType.utf8().data(), m_extensionKey.utf8().data(), errorMessage.utf8().data());
                storage->rollbackToSavepoint(savepointIdentifier.value(), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storageType, apiName, errorMessage](const String& savepointErrorMessage) mutable {
                    if (!savepointErrorMessage.isEmpty())
                        RELEASE_LOG_ERROR(Extensions, "Unable to rollback to %s rules savepoint for extension %s. Error: %s", storageType.utf8().data(), m_extensionKey.utf8().data(), savepointErrorMessage.utf8().data());
                    completionHandler(makeUnexpected(toErrorString(apiName, nullString(), errorMessage)));
                });
                return;
            }

            loadDeclarativeNetRequestRules([this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storageType, apiName, storage, savepointIdentifier = WTF::move(savepointIdentifier)](bool success) mutable {
                if (!success) {
                    storage->rollbackToSavepoint(savepointIdentifier.value(), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storageType, apiName](const String& savepointErrorMessage) mutable {
                        if (!savepointErrorMessage.isEmpty())
                            RELEASE_LOG_ERROR(Extensions, "Unable to rollback to %s rules savepoint for extension %s. Error: %s", storageType.utf8().data(), m_extensionKey.utf8().data(), savepointErrorMessage.utf8().data());
                        loadDeclarativeNetRequestRules([completionHandler = WTF::move(completionHandler), apiName](bool success) mutable {
                            if (!success)
                                return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "unable to load declarativeNetRequest rules"_s)));
                            completionHandler({ });
                        });
                    });
                    return;
                }

                storage->commitSavepoint(savepointIdentifier.value(), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), storageType](const String& savepointErrorMessage) mutable {
                    if (!savepointErrorMessage.isEmpty())
                        RELEASE_LOG_ERROR(Extensions, "Unable to commit %s rules savepoint for extension %s. Error: %s", storageType.utf8().data(), m_extensionKey.utf8().data(), savepointErrorMessage.utf8().data());
                    completionHandler({ });
                });
            });
        });
    });
}

static Ref<JSON::Array> rulesFromJSON(const String& rulesToAddJSON)
{
    if (!rulesToAddJSON.isEmpty()) {
        if (RefPtr parsedJSON = JSON::Value::parseJSON(rulesToAddJSON)) {
            if (RefPtr rulesArray = parsedJSON->asArray())
                return rulesArray.releaseNonNull();
        }
    }
    return JSON::Array::create();
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestGetDynamicRules(Vector<double>&& filter, CompletionHandler<void(Expected<String, Error>&&)>&& completionHandler)
{
    auto ruleIDs = WTF::compactMap(filter, [&](auto& ruleID) -> std::optional<double> {
        return m_dynamicRulesIDs.contains(ruleID) ? std::optional { ruleID } : std::nullopt;
    });
    declarativeNetRequestDynamicRulesStore()->getRulesWithRuleIDs(ruleIDs, [protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Array> rules, const String& errorMessage) mutable {
        if (!errorMessage.isEmpty())
            return completionHandler(makeUnexpected(toErrorString("declarativeNetRequest.getDynamicRules()"_s, nullString(), errorMessage)));
        completionHandler(rules->toJSONString());
    });
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestUpdateDynamicRules(String&& rulesToAddJSON, Vector<double>&& ruleIDsToDeleteVector, CompletionHandler<void(Expected<void, Error>&&)>&& completionHandler)
{
    static constexpr auto apiName = "declarativeNetRequest.updateDynamicRules()"_s;
    auto ruleIDsToDelete = WTF::compactMap(ruleIDsToDeleteVector, [&](auto& ruleID) -> std::optional<double> {
        return m_dynamicRulesIDs.contains(ruleID) ? std::optional { ruleID } : std::nullopt;
    });
    auto rulesToAdd = rulesFromJSON(rulesToAddJSON);
    if (!ruleIDsToDelete.size() && !rulesToAdd->length())
        return completionHandler({ });

    if (m_dynamicRulesIDs.size() + rulesToAdd->length() - ruleIDsToDelete.size() + m_sessionRulesIDs.size() > webExtensionDeclarativeNetRequestMaximumNumberOfDynamicAndSessionRules)
        return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "Failed to add dynamic rules. Maximum number of dynamic and session rules exceeded."_s)));

    updateDeclarativeNetRequestRulesInStorage(declarativeNetRequestDynamicRulesStore(), "dynamic"_s, apiName, WTF::move(rulesToAdd), WTF::move(ruleIDsToDelete), WTF::move(completionHandler));
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestGetSessionRules(Vector<double>&& filter, CompletionHandler<void(Expected<String, Error>&&)>&& completionHandler)
{
    auto ruleIDs = WTF::compactMap(filter, [&](auto& ruleID) -> std::optional<double> {
        return m_sessionRulesIDs.contains(ruleID) ? std::optional { ruleID } : std::nullopt;
    });
    declarativeNetRequestSessionRulesStore()->getRulesWithRuleIDs(ruleIDs, [protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Array> rules, const String& errorMessage) mutable {
        if (!errorMessage.isEmpty())
            return completionHandler(makeUnexpected(toErrorString("declarativeNetRequest.getSessionRules()"_s, nullString(), errorMessage)));
        completionHandler(rules->toJSONString());
    });
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestUpdateSessionRules(String&& rulesToAddJSON, Vector<double>&& ruleIDsToDeleteVector, CompletionHandler<void(Expected<void, Error>&&)>&& completionHandler)
{
    static constexpr auto apiName = "declarativeNetRequest.updateSessionRules()"_s;
    auto ruleIDsToDelete = WTF::compactMap(ruleIDsToDeleteVector, [&](auto& ruleID) -> std::optional<double> {
        return m_sessionRulesIDs.contains(ruleID) ? std::optional { ruleID } : std::nullopt;
    });
    auto rulesToAdd = rulesFromJSON(rulesToAddJSON);
    if (!ruleIDsToDelete.size() && !rulesToAdd->length())
        return completionHandler({ });

    if (m_sessionRulesIDs.size() + rulesToAdd->length() - ruleIDsToDelete.size() + m_dynamicRulesIDs.size() > webExtensionDeclarativeNetRequestMaximumNumberOfDynamicAndSessionRules)
        return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "Failed to add session rules. Maximum number of dynamic and session rules exceeded."_s)));

    updateDeclarativeNetRequestRulesInStorage(declarativeNetRequestSessionRulesStore(), "session"_s, apiName, WTF::move(rulesToAdd), WTF::move(ruleIDsToDelete), WTF::move(completionHandler));
}

// MARK: Compiling and installing

static NSString *computeStringHashForContentBlockerRules(NSString *rules)
{
    SHA1 sha1;
    sha1.addUTF8Bytes(rules);
    SHA1::Digest digest;
    sha1.computeHash(digest);
    auto hashAsCString = SHA1::hexDigest(digest);
    return [String::fromUTF8(hashAsCString.span()).createNSString().get() stringByAppendingString:[NSString stringWithFormat:@"-%zu", currentDeclarativeNetRequestRuleTranslatorVersion]];
}

void LegacyExtensionDeclarativeNetRequest::addDeclarativeNetRequestRules(WebUserContentControllerProxy& controllerProxy)
{
    if (!m_isLoaded)
        return;
    API::ContentRuleListStore::defaultStoreSingleton().lookupContentRuleListFile(declarativeNetRequestContentRuleListFilePath(), m_extensionKey.isolatedCopy(), [protectedThis = Ref { *this }, controllerProxy = Ref { controllerProxy }](RefPtr<API::ContentRuleList> ruleList, std::error_code) {
        if (!ruleList || !protectedThis->m_isLoaded)
            return;
        controllerProxy->addContentRuleList(*ruleList, protectedThis->m_root);
    });
}

void LegacyExtensionDeclarativeNetRequest::removeDeclarativeNetRequestRules()
{
    for (Ref controller : LegacyExtensionHost::singleton().userContentControllers())
        controller->removeContentRuleList(m_extensionKey);
}

void LegacyExtensionDeclarativeNetRequest::compileDeclarativeNetRequestRules(NSMutableDictionary *rulesData, CompletionHandler<void(bool)>&& completionHandler)
{
    dispatch_async(globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_HIGH, 0), makeBlockPtr([this, protectedThis = Ref { *this }, rulesData = RetainPtr { rulesData }, root = m_root.string().isolatedCopy(), completionHandler = WTF::move(completionHandler)]() mutable {
        NSArray<NSString *> *jsonDeserializationErrorStrings;
        auto *allJSONObjects = [_WKWebExtensionDeclarativeNetRequestTranslator jsonObjectsFromData:rulesData.get() errorStrings:&jsonDeserializationErrorStrings];

        NSArray<NSString *> *parsingErrorStrings;
        auto *allConvertedRules = [_WKWebExtensionDeclarativeNetRequestTranslator translateRules:allJSONObjects errorStrings:&parsingErrorStrings];

        // A content rule list's extension-path redirect replaces the URL's whole path, which drops Safari 7's
        // per-launch /<token>/; each one is a redirect to the extension file's URL instead.
        allConvertedRules = mapObjects<NSArray>(allConvertedRules, ^id(id, NSDictionary *rule) {
            NSDictionary *action = dynamic_objc_cast<NSDictionary>(rule[@"action"]);
            NSString *extensionPath = dynamic_objc_cast<NSString>(dynamic_objc_cast<NSDictionary>(action[@"redirect"])[@"extension-path"]);
            if (!extensionPath)
                return rule;
            NSMutableDictionary *redirectedAction = [action mutableCopy];
            redirectedAction[@"redirect"] = @{ @"url": URL(URL { root }, extensionPath).string().createNSString().get() };
            NSMutableDictionary *redirectedRule = [rule mutableCopy];
            redirectedRule[@"action"] = redirectedAction;
            return redirectedRule;
        });

        auto *webKitRules = encodeJSONString(allConvertedRules, JSONOptions::FragmentsAllowed);
        if (!webKitRules) {
            dispatch_async(mainDispatchQueueSingleton(), makeBlockPtr([completionHandler = WTF::move(completionHandler)]() mutable {
                completionHandler(false);
            }).get());
            return;
        }

        RetainPtr<NSString> previouslyLoadedHash = objectForKey<NSString>(m_state.get(), lastLoadedDeclarativeNetRequestHashStateKey);
        RetainPtr<NSString> hashOfWebKitRules = computeStringHashForContentBlockerRules(webKitRules);

        dispatch_async(mainDispatchQueueSingleton(), makeBlockPtr([this, protectedThis = WTF::move(protectedThis), completionHandler = WTF::move(completionHandler), previouslyLoadedHash = WTF::move(previouslyLoadedHash), hashOfWebKitRules = WTF::move(hashOfWebKitRules), webKitRules = String { webKitRules }]() mutable {
            API::ContentRuleListStore::defaultStoreSingleton().lookupContentRuleListFile(declarativeNetRequestContentRuleListFilePath(), m_extensionKey.isolatedCopy(), [this, protectedThis = WTF::move(protectedThis), completionHandler = WTF::move(completionHandler), previouslyLoadedHash = WTF::move(previouslyLoadedHash), hashOfWebKitRules = WTF::move(hashOfWebKitRules), webKitRules](RefPtr<API::ContentRuleList> foundRuleList, std::error_code) mutable {
                if (!m_isLoaded)
                    return completionHandler(false);

                if (foundRuleList && [previouslyLoadedHash isEqualToString:hashOfWebKitRules.get()]) {
                    for (Ref controller : LegacyExtensionHost::singleton().userContentControllers())
                        controller->addContentRuleList(*foundRuleList, m_root);
                    return completionHandler(true);
                }

                FileSystem::makeAllDirectories(storageDirectory());
                API::ContentRuleListStore::defaultStoreSingleton().compileContentRuleListFile(declarativeNetRequestContentRuleListFilePath(), m_extensionKey.isolatedCopy(), String(webKitRules), WebCore::ContentExtensions::CSSSelectorsAllowed::No, [this, protectedThis = WTF::move(protectedThis), completionHandler = WTF::move(completionHandler), hashOfWebKitRules](RefPtr<API::ContentRuleList> ruleList, std::error_code error) mutable {
                    if (error) {
                        RELEASE_LOG_ERROR(Extensions, "Error compiling declarativeNetRequest rules: %{public}s", error.message().c_str());
                        return completionHandler(false);
                    }
                    if (!m_isLoaded)
                        return completionHandler(false);

                    [m_state setObject:hashOfWebKitRules.get() forKey:lastLoadedDeclarativeNetRequestHashStateKey];
                    writeStateToStorage();

                    for (Ref controller : LegacyExtensionHost::singleton().userContentControllers())
                        controller->addContentRuleList(*ruleList, m_root);
                    completionHandler(true);
                });
            });
        }).get());
    }).get());
}

void LegacyExtensionDeclarativeNetRequest::loadDeclarativeNetRequestRules(CompletionHandler<void(bool)>&& completionHandler)
{
    if (!m_extension)
        return completionHandler(false);

    RetainPtr allJSONData = adoptNS([[NSMutableDictionary alloc] init]);

    auto applyDeclarativeNetRequestRules = [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler), allJSONData]() mutable {
        if (!allJSONData.get().allKeys.count) {
            removeDeclarativeNetRequestRules();
            API::ContentRuleListStore::defaultStoreSingleton().removeContentRuleListFile(declarativeNetRequestContentRuleListFilePath(), [completionHandler = WTF::move(completionHandler)](std::error_code error) mutable {
                completionHandler(!error);
            });
            return;
        }
        compileDeclarativeNetRequestRules(allJSONData.get(), WTF::move(completionHandler));
    };

    auto addStaticRulesets = [this, protectedThis = Ref { *this }, applyDeclarativeNetRequestRules = WTF::move(applyDeclarativeNetRequestRules), allJSONData]() mutable {
        RefPtr extension = m_extension;
        for (auto& ruleset : extension->declarativeNetRequestRulesets()) {
            if (!m_enabledStaticRulesetIDs.contains(ruleset.rulesetID))
                continue;
            auto jsonDataResult = extension->resourceDataForPath(ruleset.jsonPath);
            if (!jsonDataResult)
                continue;
            [allJSONData setObject:toNSData(jsonDataResult.value()->span()).get() forKey:ruleset.rulesetID.createNSString().get()];
        }
        applyDeclarativeNetRequestRules();
    };

    // The dynamic rules store opens only once the extension has a storage directory.
    auto addDynamicAndStaticRules = [this, protectedThis = Ref { *this }, addStaticRulesets = WTF::move(addStaticRulesets), allJSONData]() mutable {
        if (!m_dynamicRulesStore && !FileSystem::fileExists(storageDirectory())) {
            m_dynamicRulesIDs.clear();
            return addStaticRulesets();
        }
        declarativeNetRequestDynamicRulesStore()->getRulesWithRuleIDs({ }, [this, protectedThis = Ref { *this }, addStaticRulesets = WTF::move(addStaticRulesets), allJSONData](RefPtr<JSON::Array> rules, const String&) mutable {
            if (!rules || !rules->length()) {
                m_dynamicRulesIDs.clear();
                return addStaticRulesets();
            }
            [allJSONData setObject:toNSData(byteCast<uint8_t>(rules->toJSONString().utf8().span())).get() forKey:@"_dynamic"];
            HashSet<double> dynamicRuleIDs;
            for (const auto& rule : *rules)
                dynamicRuleIDs.add(*(rule->asObject()->getDouble("id"_s)));
            m_dynamicRulesIDs = WTF::move(dynamicRuleIDs);
            addStaticRulesets();
        });
    };

    declarativeNetRequestSessionRulesStore()->getRulesWithRuleIDs({ }, [this, protectedThis = Ref { *this }, addDynamicAndStaticRules = WTF::move(addDynamicAndStaticRules), allJSONData](RefPtr<JSON::Array> rules, const String&) mutable {
        if (!rules || !rules->length()) {
            m_sessionRulesIDs.clear();
            return addDynamicAndStaticRules();
        }
        [allJSONData setObject:toNSData(byteCast<uint8_t>(rules->toJSONString().utf8().span())).get() forKey:@"_session"];
        HashSet<double> sessionRuleIDs;
        for (const auto& rule : *rules)
            sessionRuleIDs.add(*(rule->asObject()->getDouble("id"_s)));
        m_sessionRulesIDs = WTF::move(sessionRuleIDs);
        addDynamicAndStaticRules();
    });
}

// MARK: Matched rules and action counts

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestDisplayActionCountAsBadgeText(bool displayActionCountAsBadgeText)
{
    if (displaysActionCount() == displayActionCountAsBadgeText)
        return;
    [m_state setObject:@(displayActionCountAsBadgeText) forKey:displayBlockedResourceCountAsBadgeTextStateKey];
    writeStateToStorage();
    if (displayActionCountAsBadgeText)
        return;
    for (auto tabID : copyToVector(m_actionCounts.keys())) {
        if (m_actionCountObserver)
            m_actionCountObserver(tabID, 0);
    }
    m_actionCounts.clear();
}

void LegacyExtensionDeclarativeNetRequest::declarativeNetRequestIncrementActionCount(double tabID, double increment)
{
    if (!displaysActionCount())
        return;
    auto& count = m_actionCounts.add(tabID, 0).iterator->value;
    count = std::max(0.0, count + increment);
    if (m_actionCountObserver)
        m_actionCountObserver(tabID, count);
}

std::optional<double> LegacyExtensionDeclarativeNetRequest::actionCountForTab(double tabID) const
{
    if (!displaysActionCount())
        return std::nullopt;
    return m_actionCounts.get(tabID);
}

bool LegacyExtensionDeclarativeNetRequest::displaysActionCount() const
{
    return objectForKey<NSNumber>(m_state.get(), displayBlockedResourceCountAsBadgeTextStateKey).boolValue;
}

void LegacyExtensionDeclarativeNetRequest::resetActionCount(double tabID)
{
    if (m_actionCounts.remove(tabID) && m_actionCountObserver)
        m_actionCountObserver(tabID, 0);
}

// A match is kept when the extension's website access covers its URL, as a WebExtension's host permissions
// must, for five minutes.
void LegacyExtensionDeclarativeNetRequest::handleContentRuleListNotificationForTab(double tabID, const URL& url)
{
    declarativeNetRequestIncrementActionCount(tabID, 1);
    if (!m_websiteAccess.allows(url))
        return;
    m_matchedRules.append({ url, WallTime::now(), tabID });
    if (!m_purgeMatchedRulesTimer) {
        m_purgeMatchedRulesTimer = makeUnique<RunLoop::Timer>(RunLoop::mainSingleton(), "LegacyExtensionDeclarativeNetRequest::PurgeMatchedRulesTimer"_s, this, &LegacyExtensionDeclarativeNetRequest::purgeOldMatchedRules);
        m_purgeMatchedRulesTimer->startRepeating(purgeMatchedRulesInterval);
    }
}

void LegacyExtensionDeclarativeNetRequest::purgeOldMatchedRules()
{
    purgeMatchedRulesFromBefore(WallTime::now() - purgeMatchedRulesInterval);
    if (m_matchedRules.isEmpty())
        m_purgeMatchedRulesTimer = nullptr;
}

RefPtr<WebPageProxy> LegacyExtensionDeclarativeNetRequest::activeTabOfFrontmostWindow(const Vector<Ref<WebPageProxy>>& pages)
{
    for (NSWindow *window in NSApp.orderedWindows) {
        for (auto& page : pages) {
            if (page->isInWindow() && page->platformWindow() == window)
                return page.ptr();
        }
    }
    return nullptr;
}

void LegacyExtensionDeclarativeNetRequest::tabWasRemoved(double tabID)
{
    m_actionCounts.remove(tabID);
}

void LegacyExtensionDeclarativeNetRequest::purgeMatchedRulesFromBefore(WallTime startTime)
{
    m_matchedRules.removeAllMatching([&](auto& matchedRule) {
        return matchedRule.timeStamp < startTime;
    });
}

Ref<JSON::Array> LegacyExtensionDeclarativeNetRequest::declarativeNetRequestGetMatchedRules(std::optional<double> tabID, std::optional<WallTime> minTimeStamp)
{
    purgeMatchedRulesFromBefore(WallTime::now() - purgeMatchedRulesInterval);
    auto rulesMatchedInfo = JSON::Array::create();
    for (auto& matchedRule : m_matchedRules) {
        if (tabID && matchedRule.tabID != *tabID)
            continue;
        if (!m_websiteAccess.allows(matchedRule.url))
            continue;
        if (minTimeStamp && matchedRule.timeStamp <= *minTimeStamp)
            continue;
        auto request = JSON::Object::create();
        request->setString("url"_s, matchedRule.url.string());
        auto info = JSON::Object::create();
        info->setObject("request"_s, WTF::move(request));
        info->setDouble("timeStamp"_s, std::floor(matchedRule.timeStamp.secondsSinceEpoch().milliseconds()));
        info->setDouble("tabId"_s, matchedRule.tabID);
        rulesMatchedInfo->pushObject(WTF::move(info));
    }
    return rulesMatchedInfo;
}

// MARK: API calls

static NSString *invalidRule(NSDictionary *options, NSString *rulesetID)
{
    NSString *ruleErrorString;
    size_t index = 0;
    for (NSDictionary *ruleDictionary in objectForKey<NSArray>(options, addRulesKey, false, NSDictionary.class)) {
        if (!adoptNS([[_WKWebExtensionDeclarativeNetRequestRule alloc] initWithDictionary:ruleDictionary rulesetID:rulesetID errorString:&ruleErrorString]))
            return toErrorString(nullString(), addRulesKey, makeString("an error with rule at index "_s, index, ": "_s, String(ruleErrorString))).createNSString().autorelease();
        ++index;
    }
    return nil;
}

static Vector<double> ruleIDs(NSDictionary *dictionary, NSString *key)
{
    Vector<double> result;
    for (NSNumber *ruleID in objectForKey<NSArray>(dictionary, key, false, NSNumber.class))
        result.append(ruleID.doubleValue);
    return result;
}

void LegacyExtensionDeclarativeNetRequest::performCall(const String& method, RefPtr<JSON::Value>&& argument, Function<bool(double tabID)>&& tabExists, CompletionHandler<void(CallResult&&)>&& completionHandler)
{
    if (!m_hasLoadedRules) {
        m_callsWaitingForRules.append([this, protectedThis = Ref { *this }, method, argument = WTF::move(argument), tabExists = WTF::move(tabExists), completionHandler = WTF::move(completionHandler)]() mutable {
            performCall(method, WTF::move(argument), WTF::move(tabExists), WTF::move(completionHandler));
        });
        return;
    }

    auto apiName = makeString("declarativeNetRequest."_s, method, "()"_s);
    // An omitted argument arrives as null.
    id parsedArgument = argument && argument->type() != JSON::Value::Type::Null ? parseJSON(argument->toJSONString().createNSString().get(), JSONOptions::FragmentsAllowed) : nil;
    NSDictionary *options = dynamic_objc_cast<NSDictionary>(parsedArgument);
    if (parsedArgument && !options)
        return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "the argument is not an object"_s)));

    NSString *exceptionString;
    auto invalidCall = [&] {
        completionHandler(makeUnexpected(toErrorString(apiName, nullString(), exceptionString)));
    };
    // The completion of a method that answers nothing.
    auto withoutResult = [](CompletionHandler<void(CallResult&&)>&& completionHandler) {
        return [completionHandler = WTF::move(completionHandler)](Expected<void, Error>&& result) mutable {
            if (!result)
                return completionHandler(makeUnexpected(result.error()));
            completionHandler(RefPtr<JSON::Value> { });
        };
    };

    if (method == "updateEnabledRulesets"_s) {
        static NSDictionary<NSString *, id> *types = @{
            disableRulesetsKey: @[ NSString.class ],
            enableRulesetsKey: @[ NSString.class ],
        };
        if (!validateDictionary(options, @"options", nil, types, &exceptionString))
            return invalidCall();
        auto toVector = [](NSArray *array) {
            Vector<String> result;
            for (NSString *identifier in array)
                result.append(identifier);
            return result;
        };
        declarativeNetRequestUpdateEnabledRulesets(toVector(objectForKey<NSArray>(options, enableRulesetsKey, true, NSString.class)), toVector(objectForKey<NSArray>(options, disableRulesetsKey, true, NSString.class)), withoutResult(WTF::move(completionHandler)));
        return;
    }

    if (method == "getEnabledRulesets"_s) {
        declarativeNetRequestGetEnabledRulesets([completionHandler = WTF::move(completionHandler)](Vector<String>&& rulesets) mutable {
            auto array = JSON::Array::create();
            for (auto& ruleset : rulesets)
                array->pushString(ruleset);
            completionHandler(RefPtr<JSON::Value> { WTF::move(array) });
        });
        return;
    }

    if (method == "updateDynamicRules"_s || method == "updateSessionRules"_s) {
        static NSDictionary<NSString *, id> *keyTypes = @{
            addRulesKey: @[ NSDictionary.class ],
            removeRulesKey: @[ NSNumber.class ],
        };
        if (!validateDictionary(options, @"options", nil, keyTypes, &exceptionString))
            return invalidCall();
        bool isDynamic = method == "updateDynamicRules"_s;
        if ((exceptionString = invalidRule(options, isDynamic ? @"_dynamic" : @"_session")))
            return invalidCall();
        String rulesToAddJSON;
        if (NSArray *rulesToAdd = objectForKey<NSArray>(options, addRulesKey, false, NSDictionary.class))
            rulesToAddJSON = encodeJSONString(rulesToAdd, JSONOptions::FragmentsAllowed);
        if (isDynamic)
            declarativeNetRequestUpdateDynamicRules(WTF::move(rulesToAddJSON), ruleIDs(options, removeRulesKey), withoutResult(WTF::move(completionHandler)));
        else
            declarativeNetRequestUpdateSessionRules(WTF::move(rulesToAddJSON), ruleIDs(options, removeRulesKey), withoutResult(WTF::move(completionHandler)));
        return;
    }

    if (method == "getDynamicRules"_s || method == "getSessionRules"_s) {
        static NSDictionary<NSString *, id> *keyTypes = @{
            getDynamicOrSessionRulesRuleIDsKey: @[ NSNumber.class ]
        };
        if (!validateDictionary(options, nil, nil, keyTypes, &exceptionString))
            return invalidCall();
        auto completion = [completionHandler = WTF::move(completionHandler)](Expected<String, Error>&& result) mutable {
            if (!result)
                return completionHandler(makeUnexpected(result.error()));
            completionHandler(JSON::Value::parseJSON(result.value()));
        };
        auto filter = ruleIDs(options, getDynamicOrSessionRulesRuleIDsKey);
        if (method == "getDynamicRules"_s)
            declarativeNetRequestGetDynamicRules(WTF::move(filter), WTF::move(completion));
        else
            declarativeNetRequestGetSessionRules(WTF::move(filter), WTF::move(completion));
        return;
    }

    if (method == "getMatchedRules"_s) {
        static NSDictionary<NSString *, id> *keyTypes = @{
            getMatchedRulesTabIDKey: NSNumber.class,
            getMatchedRulesMinTimeStampKey: NSNumber.class,
        };
        if (!validateDictionary(options, nil, nil, keyTypes, &exceptionString))
            return invalidCall();
        NSNumber *tabID = objectForKey<NSNumber>(options, getMatchedRulesTabIDKey);
        if (tabID && !tabExists(tabID.doubleValue))
            return completionHandler(makeUnexpected(toErrorString(apiName, nullString(), "tab not found"_s)));
        NSNumber *minTimeStamp = objectForKey<NSNumber>(options, getMatchedRulesMinTimeStampKey);
        auto info = JSON::Object::create();
        info->setArray("rulesMatchedInfo"_s, declarativeNetRequestGetMatchedRules(tabID ? std::optional { tabID.doubleValue } : std::nullopt, minTimeStamp ? std::optional { WallTime::fromRawSeconds(Seconds::fromMilliseconds(minTimeStamp.doubleValue).value()) } : std::nullopt));
        completionHandler(RefPtr<JSON::Value> { WTF::move(info) });
        return;
    }

    if (method == "isRegexSupported"_s) {
        static NSDictionary<NSString *, Class> *types = @{
            regexKey: NSString.class,
            regexIsCaseSensitiveKey: @YES.class,
            regexRequireCapturingKey: @YES.class,
        };
        if (!validateDictionary(options, @"regexOptions", @[ regexKey ], types, &exceptionString))
            return invalidCall();
        auto result = JSON::Object::create();
        bool isSupported = [WKContentRuleList _supportsRegularExpression:objectForKey<NSString>(options, regexKey)];
        result->setBoolean("isSupported"_s, isSupported);
        if (!isSupported)
            result->setString("reason"_s, "syntaxError"_s);
        completionHandler(RefPtr<JSON::Value> { WTF::move(result) });
        return;
    }

    if (method == "setExtensionActionOptions"_s) {
        static NSDictionary<NSString *, Class> *types = @{
            actionCountDisplayActionCountAsBadgeTextKey: @YES.class,
            actionCountTabUpdateKey: NSDictionary.class
        };
        if (!validateDictionary(options, @"extensionActionOptions", nil, types, &exceptionString))
            return invalidCall();
        if (NSDictionary *tabUpdate = objectForKey<NSDictionary>(options, actionCountTabUpdateKey)) {
            static NSDictionary<NSString *, Class> *tabUpdateTypes = @{
                actionCountTabIDKey: NSNumber.class,
                actionCountIncrementKey: NSNumber.class
            };
            if (!validateDictionary(tabUpdate, @"tabUpdate", @[ actionCountTabIDKey, actionCountIncrementKey ], tabUpdateTypes, &exceptionString))
                return invalidCall();
            double tabID = objectForKey<NSNumber>(tabUpdate, actionCountTabIDKey).doubleValue;
            if (!tabExists(tabID))
                return completionHandler(makeUnexpected(toErrorString("declarativeNetRequest.setExtensionActionOptions()"_s, nullString(), "tab not found"_s)));
            declarativeNetRequestIncrementActionCount(tabID, objectForKey<NSNumber>(tabUpdate, actionCountIncrementKey).doubleValue);
            return completionHandler(RefPtr<JSON::Value> { });
        }
        declarativeNetRequestDisplayActionCountAsBadgeText(objectForKey<NSNumber>(options, actionCountDisplayActionCountAsBadgeTextKey).boolValue);
        return completionHandler(RefPtr<JSON::Value> { });
    }

    completionHandler(makeUnexpected(makeString("declarativeNetRequest."_s, method, " is not supported."_s)));
}

} // namespace WebKit
