'use strict';

const SERVER = 'http://127.0.0.1:8843';
const report = (key, value) => {
    fetch(`${SERVER}/report?${encodeURIComponent(key)}=${encodeURIComponent(JSON.stringify(value))}`).catch(() => {});
};

report('global-loaded', { browser: typeof browser, namespaces: Object.keys(browser), baseURI: safari.extension.baseURI });

// One module, whichever way it is addressed.
Promise.all([import('/mod.js'), import('./mod.js')]).then(
    ([a, b]) => report('module-identity', { same: a === b }),
    error => report('module-identity', { error: String(error) })
);

browser.webRequest.onBeforeRequest.addListener(details => {
    report('onBeforeRequest', details);
    if (details.url.includes('/blocked-'))
        return { cancel: true };
    if (details.url.includes('/redirect-'))
        return { redirectUrl: 'data:text/javascript,window.__redirected=true' };
    if (details.url.includes('/slow-ws'))
        return new Promise(resolve => setTimeout(() => resolve({}), 2000));
}, { urls: ['http://127.0.0.1/*', 'ws://127.0.0.1/*'] }, ['blocking']);

browser.webRequest.onHeadersReceived.addListener(details => {
    report('onHeadersReceived', { url: details.url, type: details.type, statusCode: details.statusCode });
    if (details.url.includes('/blocked-by-headers'))
        return { cancel: true };
    if (details.url.includes('/csp-page')) {
        details.responseHeaders.push({ name: 'X-Legacy-Extension', value: 'modified' });
        return { responseHeaders: details.responseHeaders };
    }
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'responseHeaders']);

// An extension page's permission read waits on this listener's verdict while its process is blocked on it.
browser.webRequest.onBeforeRequest.addListener(details => {
    report('manifest-request', { url: details.url, type: details.type, tabId: details.tabId });
    return new Promise(resolve => setTimeout(() => resolve({}), 200));
}, { urls: ['safari-extension://*/*manifest.json'] }, ['blocking']);

// onHeadersReceived for a redirect: cancel one, move another by its Location header; and a response the
// extension redirects after its headers arrive.
browser.webRequest.onHeadersReceived.addListener(details => {
    if (details.url.includes('/moved-cancel'))
        return { cancel: true };
    if (details.url.includes('/moved-location')) {
        report('redirect-headers', { statusCode: details.statusCode, statusLine: details.statusLine, location: details.responseHeaders.find(h => h.name.toLowerCase() === 'location') });
        return { responseHeaders: details.responseHeaders.map(h => h.name.toLowerCase() === 'location' ? { name: h.name, value: '/res/location-rewritten.json' } : h) };
    }
    if (details.url.endsWith('/res/headers-redirect.json'))
        return { redirectUrl: 'http://127.0.0.1:8843/res/headers-redirected.json' };
    // Redirects of a response the cache served, one the cache revalidated, and a form post's.
    if (details.url.endsWith('/cacheable.json') && details.fromCache)
        return { redirectUrl: 'http://127.0.0.1:8843/res/cache-redirected.json' };
    if (details.url.endsWith('/revalidate.json') && details.fromCache)
        return { redirectUrl: 'http://127.0.0.1:8843/res/reval-redirected.json' };
    if (details.url.endsWith('/post-redirect'))
        return { redirectUrl: 'http://127.0.0.1:8843/res/post-redirected.json' };
    // A same-origin redirect carrying the page's Authorization, sent to another origin; a script sent to data:.
    if (details.url.endsWith('/auth-hop'))
        return { redirectUrl: 'http://localhost:8843/echo-headers?auth-cross' };
    if (details.url.endsWith('/auth-hop-same'))
        return { redirectUrl: 'http://127.0.0.1:8843/echo-headers?auth-same' };
    if (details.url.endsWith('/moved-script'))
        return { redirectUrl: 'data:text/javascript,window.__redirectData%3Dtrue' };
    if (details.url.endsWith('/res/hdr-data-script.js'))
        return { redirectUrl: 'data:text/javascript,window.__headersData%3Dtrue' };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'responseHeaders']);

// A top-level form post the extension redirects before it is sent keeps its method and body; a navigation
// the extension sends to its own page.
browser.webRequest.onBeforeRequest.addListener(details => {
    if (details.url.endsWith('/main-post'))
        return { redirectUrl: 'http://127.0.0.1:8843/main-post-target' };
    if (details.url.endsWith('/to-extension-page'))
        return { redirectUrl: `${safari.extension.baseURI}blocked.html` };
}, { urls: ['http://127.0.0.1/*'], types: ['main_frame'] }, ['blocking']);
browser.webRequest.onHeadersReceived.addListener(details => {
    if (details.url.endsWith('/to-data'))
        return { redirectUrl: 'data:text/html,<title>data document</title>' };
}, { urls: ['http://127.0.0.1/*'], types: ['main_frame'] }, ['blocking']);

// "extraHeaders": Set-Cookie seen and stripped, Cookie seen, removed and changed; listeners without it see neither.
browser.webRequest.onHeadersReceived.addListener(details => {
    if (!details.url.includes('/set-cookies'))
        return;
    const cookies = details.responseHeaders.filter(h => h.name.toLowerCase() === 'set-cookie').map(h => h.value);
    report('set-cookie-seen', { cookies });
    return { responseHeaders: details.responseHeaders.filter(h => !(h.name.toLowerCase() === 'set-cookie' && h.value.startsWith('strip='))) };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'responseHeaders', 'extraHeaders']);
browser.webRequest.onHeadersReceived.addListener(details => {
    if (details.url.includes('/set-cookies'))
        report('set-cookie-unrequested', { visible: details.responseHeaders.some(h => h.name.toLowerCase() === 'set-cookie') });
}, { urls: ['http://127.0.0.1/*'] }, ['responseHeaders']);
browser.webRequest.onBeforeSendHeaders.addListener(details => {
    const header = name => (details.requestHeaders.find(h => h.name.toLowerCase() === name) || {}).value;
    const cookie = details.requestHeaders.find(h => h.name.toLowerCase() === 'cookie');
    if (details.url.endsWith('/echo-headers?see'))
        report('cookie-seen', { cookie: cookie && cookie.value, acceptLanguage: header('accept-language'), acceptEncoding: header('accept-encoding') });
    if (details.url.endsWith('/cookie-hop'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'cookie') };
    if (details.url.endsWith('/echo-headers?hop2') || details.url.endsWith('/echo-headers?after-set-cookie'))
        report(`cookie-shown${new URL(details.url).search}`, { cookie: header('cookie') });
    if (details.url.endsWith('/echo-headers?language'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'accept-language').concat({ name: 'Accept-Language', value: 'x-test' }) };
    if (details.url.endsWith('/echo-headers?no-encoding'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'accept-encoding') };
    if (details.url.endsWith('/echo-headers?strip'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'cookie') };
    if (details.url.endsWith('/echo-headers?modify'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'cookie').concat({ name: 'Cookie', value: 'keep=changed' }) };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'requestHeaders', 'extraHeaders']);
browser.webRequest.onBeforeSendHeaders.addListener(details => {
    if (details.url.endsWith('/echo-headers?see'))
        report('cookie-unrequested', { visible: details.requestHeaders.filter(h => ['cookie', 'accept-language', 'accept-encoding'].includes(h.name.toLowerCase())).map(h => h.name) });
}, { urls: ['http://127.0.0.1/*'] }, ['requestHeaders']);
browser.webRequest.onSendHeaders.addListener(details => {
    if (details.url.endsWith('/echo-headers?hop2') || details.url.endsWith('/echo-headers?after-set-cookie') || details.url.endsWith('/echo-headers?see'))
        report(`cookie-sent${new URL(details.url).search}`, { cookie: (details.requestHeaders.find(h => h.name.toLowerCase() === 'cookie') || {}).value });
}, { urls: ['http://127.0.0.1/*'] }, ['requestHeaders', 'extraHeaders']);

browser.webRequest.onBeforeRedirect.addListener(details => {
    if (details.url.includes('/moved-location') || details.url.includes('/headers-redirect') || details.url.includes('/main-post'))
        report('onBeforeRedirect', { url: details.url, redirectUrl: details.redirectUrl, statusCode: details.statusCode, hasHeaders: 'responseHeaders' in details });
}, { urls: ['http://127.0.0.1/*'] });

// onBeforeSendHeaders: add and remove a header, cancel a request; onSendHeaders sees the result.
browser.webRequest.onBeforeSendHeaders.addListener(details => {
    if (details.url.includes('/stopped-send-headers'))
        return { cancel: true };
    if (details.url.includes('/echo-headers'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'x-remove-me').concat({ name: 'X-Legacy-Extension-Request', value: 'added' }) };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'requestHeaders']);
browser.webRequest.onSendHeaders.addListener(details => {
    if (details.url.includes('/echo-headers'))
        report('onSendHeaders', { names: details.requestHeaders.map(h => h.name.toLowerCase()) });
}, { urls: ['http://127.0.0.1/*'] }, ['requestHeaders']);
browser.webRequest.onSendHeaders.addListener(details => {
    if (details.url.includes('/echo-headers'))
        report('onSendHeaders-unrequested', { hasHeaders: 'requestHeaders' in details });
}, { urls: ['http://127.0.0.1/*'] });

// requestBody, for the listener that asks for it only.
const bodyText = body => body && {
    formData: body.formData,
    raw: body.raw && body.raw.map(element => element.bytes instanceof ArrayBuffer ? { bytes: new TextDecoder().decode(element.bytes) } : element),
};
browser.webRequest.onBeforeRequest.addListener(details => {
    if (details.method === 'POST' && details.url.includes('/post-'))
        report(`requestBody${new URL(details.url).pathname}`, bodyText(details.requestBody));
}, { urls: ['http://127.0.0.1/*'] }, ['requestBody']);
browser.webRequest.onBeforeRequest.addListener(details => {
    if (details.method === 'POST' && details.url.includes('/post-urlencoded'))
        report('requestBody-unrequested', { hasBody: 'requestBody' in details });
}, { urls: ['http://127.0.0.1/*'] });

browser.webRequest.onCompleted.addListener(details => {
    if (details.url.includes('/res/allowed-fetch.json'))
        report('onCompleted', { statusCode: details.statusCode, statusLine: details.statusLine, fromCache: details.fromCache, hasHeaders: 'responseHeaders' in details });
}, { urls: ['http://127.0.0.1/*'] }, ['responseHeaders']);
browser.webRequest.onErrorOccurred.addListener(details => {
    if (details.url.includes('/stopped-send-headers'))
        report('onErrorOccurred', { error: details.error, fromCache: details.fromCache });
    else if (!details.url.includes('/report?'))
        report('load-error', { url: details.url, requestId: details.requestId, type: details.type, error: details.error });
}, { urls: ['http://127.0.0.1/*'] });

browser.webNavigation.onCommitted.addListener(details => report('onCommitted', details));
browser.webNavigation.onCreatedNavigationTarget.addListener(details => report('onCreatedNavigationTarget', details));
browser.tabs.onRemoved.addListener(tabId => report('onRemoved', { tabId }));

browser.runtime.onConnect.addListener(port => {
    report('onConnect', { name: port.name, sender: port.sender });
    port.onMessage.addListener(async message => {
        const { tab, frameId } = port.sender;
        switch (message.what) {
        case 'hello':
            port.postMessage({ what: 'hello', echo: message });
            break;
        case 'css':
            await browser.tabs.insertCSS(tab.id, { code: '#css-target { display: none !important; }', frameId, cssOrigin: 'user' });
            port.postMessage({ what: 'css' });
            break;
        case 'exec': {
            const result = await browser.tabs.executeScript(tab.id, { code: 'document.documentElement.dataset.execRan = "yes"; 6 * 7', frameId });
            port.postMessage({ what: 'exec', result });
            break;
        }
        case 'cssfile':
            await browser.tabs.insertCSS(tab.id, { file: 'inject.css', frameId });
            await browser.tabs.insertCSS(tab.id, { code: '#css-code-target { background-image: url(res/code-probe.png); }', frameId });
            port.postMessage({ what: 'cssfile' });
            break;
        case 'cssremove':
            await browser.tabs.removeCSS(tab.id, { code: '#css-code-target { background-image: url(res/code-probe.png); }', frameId });
            port.postMessage({ what: 'cssremove' });
            break;
        case 'aboutblank': {
            const where = 'location.href';
            const without = await browser.tabs.executeScript(tab.id, { code: where, allFrames: true });
            const withBlank = await browser.tabs.executeScript(tab.id, { code: where, allFrames: true, matchAboutBlank: true });
            const blankOnly = await browser.tabs.executeScript(tab.id, { code: where, frameId: message.blankFrameId }).then(r => r, error => 'error:' + error.message);
            port.postMessage({ what: 'aboutblank', without, withBlank, blankOnly });
            break;
        }
        case 'frames': {
            const frames = await browser.webNavigation.getAllFrames({ tabId: tab.id });
            const info = await browser.tabs.get(tab.id);
            port.postMessage({ what: 'frames', frames, tab: info });
            break;
        }
        }
    });
    port.onDisconnect.addListener(() => report('onDisconnect', { name: port.name }));
});

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    report('onMessage', { message, sender });
    sendResponse({ echo: message });
});

// The extension's own files, addressed from the origin's root.
fetch('/content.js').then(r => r.text()).then(
    text => report('root-relative-fetch', { ok: text.length !== 0 }),
    error => report('root-relative-fetch', { ok: false, error: String(error) })
);
{
    const xhr = new XMLHttpRequest();
    xhr.open('GET', '/content.js', false);
    try { xhr.send(); } catch { }
    report('root-relative-sync-xhr', { ok: xhr.responseText.length !== 0 });
}

// A Blob read back through FileReader.
{
    const reader = new FileReader();
    reader.onload = () => report('filereader', { ok: true, result: reader.result });
    reader.onerror = () => report('filereader', { ok: false, error: String(reader.error) });
    reader.readAsDataURL(new Blob([ 'x' ], { type: 'text/plain' }));
}
{
    const blobURL = URL.createObjectURL(new Blob([ 'x' ]));
    fetch(blobURL).then(r => r.text()).then(
        text => report('blob-fetch', { ok: true, text, blobURL, origin: self.origin }),
        error => report('blob-fetch', { ok: false, error: String(error), blobURL, origin: self.origin })
    );
}

safari.application.addEventListener('contextmenu', event => {
    const info = event.userInfo;
    report('contextmenu-userinfo', { json: JSON.stringify(info), types: info && Object.fromEntries(Object.entries(info).map(([k, v]) => [k, Array.isArray(v) ? 'array' : typeof v])) });
}, false);

// The clipboard, well after any user gesture, as a password manager clears what it copied.
(async () => {
    const clipboard = navigator.clipboard;
    const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
    const result = {
        type: Object.prototype.toString.call(clipboard),
        writeTextLength: clipboard.writeText.length,
    };
    try {
        await fetch(`${SERVER}/report?clipboard-start=${Date.now()}`);
        await wait(1500);
        const copied = `legacy-extension-clipboard-${Date.now()}`;
        result.write = await clipboard.writeText(copied);
        result.readBack = await clipboard.readText() === copied;
        result.systemPasteboard = await (await fetch(`${SERVER}/pbpaste`)).text() === copied;

        await wait(1000);
        if (await clipboard.readText() === copied)
            await clipboard.writeText('');
        result.clearedUnchanged = await clipboard.readText() === '';

        await clipboard.writeText(copied);
        const external = `external-${Date.now()}`;
        await fetch(`${SERVER}/pbcopy?${encodeURIComponent(external)}`);
        await wait(500);
        if (await clipboard.readText() === copied)
            await clipboard.writeText('');
        result.keptExternal = await clipboard.readText() === external;

        result.wrongThis = await clipboard.writeText.call({}, 'x').then(() => 'resolved', error => error.name);
    } catch (error) {
        result.error = `${error.name}: ${error.message}`;
    }
    report('clipboard', result);
})();
