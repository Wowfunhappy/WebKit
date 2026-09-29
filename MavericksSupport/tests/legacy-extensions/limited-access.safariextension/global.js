'use strict';

// Website access that Info.plist grants: localhost over http, and nothing else. The router and the network
// process keep everything else from this extension: other sites' cookies, and every webRequest event for
// them. The clipboard is every extension page's.
const report = (key, value) => fetch(`http://127.0.0.1:8843/report?${key}=${encodeURIComponent(JSON.stringify(value))}`);
const outcome = promise => promise.then(value => ({ resolved: value }), error => ({ rejected: error.message || error.name }));

// Any event outside the access is a leak; the localhost probe's is the expected one.
const outside = url => !/^http:\/\/localhost[:/]/.test(url);
browser.webRequest.onBeforeRequest.addListener(details => {
    if (outside(details.url))
        report('limited-access-leak', { event: 'onBeforeRequest', url: details.url });
}, { urls: ['<all_urls>'] });
browser.webRequest.onBeforeSendHeaders.addListener(details => {
    if (outside(details.url))
        report('limited-access-leak', { event: 'onBeforeSendHeaders', url: details.url });
    else if (details.url.includes('limited-access'))
        report('limited-access-saw', { url: details.url, cookie: (details.requestHeaders.find(h => h.name.toLowerCase() === 'cookie') || {}).value || null });
}, { urls: ['<all_urls>'] }, ['blocking', 'requestHeaders', 'extraHeaders']);

(async () => {
    await fetch('http://127.0.0.1:8843/report?limited-access-start=1');
    const changes = [];
    browser.cookies.onChanged.addListener(change => changes.push(change.cookie.domain));
    const result = {
        clipboard: await outcome(navigator.clipboard.writeText('limited-access').then(() => navigator.clipboard.readText())),
        otherHost: await outcome(browser.cookies.get({ url: 'http://127.0.0.1:8843/', name: 'keep' })),
        securePage: await outcome(browser.cookies.get({ url: 'https://localhost:8843/', name: 'limited' })),
        set: await outcome(browser.cookies.set({ url: 'http://localhost:8843/', name: 'limited', value: '1' }).then(cookie => cookie && cookie.domain)),
        setOtherHost: await outcome(browser.cookies.set({ url: 'http://127.0.0.1:8843/', name: 'limited', value: '1' })),
        getAllDomains: await outcome(browser.cookies.getAll({}).then(cookies => [...new Set(cookies.map(cookie => cookie.domain))])),
    };

    // With the page's own JSON.parse and Array.prototype.filter replaced, getAll still answers only what the
    // router lets through.
    const { parse } = JSON;
    const { filter } = Array.prototype;
    JSON.parse = function (text, ...rest) { return parse.call(this, text, ...rest); };
    Array.prototype.filter = function () { return Array.from(this); };
    try {
        result.subvertedGetAllDomains = await outcome(browser.cookies.getAll({}).then(cookies => [...new Set(cookies.map(cookie => cookie.domain))]));
    } finally {
        JSON.parse = parse;
        Array.prototype.filter = filter;
    }

    await browser.cookies.remove({ url: 'http://localhost:8843/', name: 'limited' });
    await new Promise(resolve => setTimeout(resolve, 1500));
    result.changedDomains = [...new Set(changes)];
    report('limited-access', result);
})();
