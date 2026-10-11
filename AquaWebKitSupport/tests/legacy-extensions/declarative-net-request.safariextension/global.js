'use strict';

// Sets up declarativeNetRequest rules for pages/dnr.html and reports what the API answers. Dynamic rules
// persist: `dnr-dynamic-at-load` names the ones a previous launch left.
const report = (key, value) => fetch(`http://127.0.0.1:8843/report?${key}=${encodeURIComponent(JSON.stringify(value))}`);
const outcome = promise => promise.then(value => ({ resolved: value === undefined ? null : value }), error => ({ rejected: error.message }));
const base = 'http://127.0.0.1:8843/dnr/';
const dnr = browser.declarativeNetRequest;

(async () => {
    const existing = await dnr.getDynamicRules();
    await report('dnr-dynamic-at-load', existing.map(rule => rule.id));
    const result = {};
    result.updateDynamicRules = await outcome(dnr.updateDynamicRules({ removeRuleIds: existing.map(rule => rule.id), addRules: [
        { id: 1, priority: 1, action: { type: 'block' }, condition: { urlFilter: '/dnr/dynamic-blocked', resourceTypes: ['xmlhttprequest'] } },
        { id: 2, priority: 2, action: { type: 'allow' }, condition: { urlFilter: '/dnr/dynamic-blocked-allowed', resourceTypes: ['xmlhttprequest'] } },
        { id: 3, action: { type: 'redirect', redirect: { url: `${base}sent.json` } }, condition: { urlFilter: '/dnr/send-elsewhere', resourceTypes: ['xmlhttprequest'] } },
        { id: 4, action: { type: 'redirect', redirect: { extensionPath: '/landing.html' } }, condition: { urlFilter: '/dnr/to-extension', resourceTypes: ['main_frame'] } },
        { id: 5, action: { type: 'modifyHeaders', requestHeaders: [{ header: 'Accept-Language', operation: 'set', value: 'x-dnr' }] }, condition: { urlFilter: '/echo-headers?dnr', resourceTypes: ['xmlhttprequest'] } },
        { id: 6, action: { type: 'block' }, condition: { urlFilter: '||localhost:8843/dnr/outside-blocked', resourceTypes: ['xmlhttprequest'] } },
    ] }));
    // Session rules last while the extension is loaded, so a reload of this page finds them.
    const sessionAtLoad = (await dnr.getSessionRules()).map(rule => rule.id);
    await report('dnr-session-at-load', sessionAtLoad);
    result.updateSessionRules = await outcome(dnr.updateSessionRules({ removeRuleIds: sessionAtLoad, addRules: [
        { id: 10, action: { type: 'block' }, condition: { urlFilter: '/dnr/session-blocked', resourceTypes: ['xmlhttprequest'] } },
    ] }));
    result.dynamicRuleIDs = (await dnr.getDynamicRules()).map(rule => rule.id);
    result.filteredDynamicRuleIDs = (await dnr.getDynamicRules({ ruleIds: [3] })).map(rule => rule.id);
    result.sessionRuleIDs = (await dnr.getSessionRules()).map(rule => rule.id);
    result.invalidRule = await outcome(dnr.updateDynamicRules({ addRules: [{ id: 99, condition: {} }] }));
    result.invalidOptions = await outcome(dnr.updateDynamicRules({ addRules: 'nope' }));
    result.enabledAtLoad = await dnr.getEnabledRulesets();
    result.enableStaticOff = await outcome(dnr.updateEnabledRulesets({ enableRulesetIds: ['static_off'] }));
    result.enabledAfter = await dnr.getEnabledRulesets();
    result.enableUnknown = await outcome(dnr.updateEnabledRulesets({ enableRulesetIds: ['nope'] }));
    result.regexSupported = await dnr.isRegexSupported({ regex: '^https?://[a-z]+\\.example/' });
    result.regexUnsupported = await dnr.isRegexSupported({ regex: '(?<=a)b' });
    result.actionOptions = await outcome(dnr.setExtensionActionOptions({ displayActionCountAsBadgeText: true }));
    result.callbackForm = await new Promise(resolve => dnr.getEnabledRulesets(rulesets => resolve(rulesets)));
    result.constants = [dnr.MAX_NUMBER_OF_STATIC_RULESETS, dnr.MAX_NUMBER_OF_ENABLED_STATIC_RULESETS, dnr.MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES];
    await report('dnr-api', result);
})();

// Once pages/dnr.html has made its loads, the rules they matched.
browser.webNavigation.onCompleted.addListener(details => {
    if (!details.url.includes('/dnr.html') || details.frameId)
        return;
    setTimeout(async () => {
        const matched = await outcome(dnr.getMatchedRules({ tabId: details.tabId }));
        report('dnr-matched', matched.resolved ? matched.resolved.rulesMatchedInfo.map(info => info.request.url.replace(/^https?:\/\/[^/]+/, '')) : matched);
    }, 2000);
});

// reload.html asks for this page to reload, to show its session rules outlasting it.
browser.runtime.onMessage.addListener(message => {
    if (message && message.reloadGlobalPage)
        setTimeout(() => location.reload(), 100);
});

// The badge the extension's toolbar item shows, whenever it changes.
let lastBadge;
setInterval(() => {
    const badge = safari.extension.toolbarItems.map(item => item.badge).join(',');
    if (badge !== lastBadge)
        report('dnr-badge', (lastBadge = badge));
}, 250);
