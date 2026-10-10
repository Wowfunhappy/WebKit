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

// The global page's own requests reach its listeners too; its reports are left out of them.
const isReport = details => details.url.includes('/report?');

browser.webRequest.onBeforeRequest.addListener(details => {
    if (isReport(details))
        return;
    report('onBeforeRequest', details);
    if (details.url.includes('/blocked-'))
        return { cancel: true };
    if (details.url.includes('/redirect-'))
        return { redirectUrl: 'data:text/javascript,window.__redirected=true' };
    if (details.url.includes('/slow-ws'))
        return new Promise(resolve => setTimeout(() => resolve({}), 2000));
}, { urls: ['http://127.0.0.1/*', 'ws://127.0.0.1/*'] }, ['blocking']);

browser.webRequest.onHeadersReceived.addListener(details => {
    if (isReport(details))
        return;
    report('onHeadersReceived', { url: details.url, type: details.type, statusCode: details.statusCode });
    if (details.url.includes('/blocked-by-headers'))
        return { cancel: true };
    if (details.url.includes('/csp-page')) {
        details.responseHeaders.push({ name: 'X-Legacy-Extension', value: 'modified' });
        return { responseHeaders: details.responseHeaders };
    }
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'responseHeaders']);

// onAuthRequired: credentials from an asyncBlocking listener, a cancel from a blocking one.
browser.webRequest.onAuthRequired.addListener((details, callback) => {
    if (!details.url.includes('/auth-basic'))
        return callback({});
    report('onAuthRequired', { url: details.url, scheme: details.scheme, realm: details.realm, challenger: details.challenger, isProxy: details.isProxy, statusCode: details.statusCode, type: details.type, requestId: typeof details.requestId });
    setTimeout(() => callback({ authCredentials: { username: 'extension', password: 'secret' } }), 100);
}, { urls: ['http://127.0.0.1/*'] }, ['asyncBlocking']);
browser.webRequest.onAuthRequired.addListener(details => {
    if (details.url.includes('/auth-cancel'))
        return { cancel: true };
}, { urls: ['http://127.0.0.1/*', 'http://localhost/*'] }, ['blocking']);

// webNavigation's start, completion and failure of navigations to the test server.
for (const name of ['onBeforeNavigate', 'onCompleted', 'onErrorOccurred']) {
    browser.webNavigation[name].addListener(details => {
        if (/127\.0\.0\.1:(8843|8849|1)\//.test(details.url) && !details.url.includes('/report?'))
            report(`nav-${name}`, { url: details.url, frameId: details.frameId, parentFrameId: details.parentFrameId, tabId: typeof details.tabId, error: details.error });
    });
}

// A navigation the extension cancels.
browser.webRequest.onBeforeRequest.addListener(details => {
    if (details.url.endsWith('/cancelled-document'))
        return { cancel: true };
}, { urls: ['http://127.0.0.1/*'], types: ['main_frame'] }, ['blocking']);

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
    if (message.what === 'cookies')
        return cookiesTest();
    sendResponse({ echo: message });
});

// cookies with website access to every site: set, read back as a request sends it, list, remove; each
// change reaching onChanged.
async function cookiesTest() {
    const changes = [];
    const onChanged = change => {
        if (change.cookie.name === 'extension-cookie')
            changes.push({ removed: change.removed, cause: change.cause, value: change.cookie.value });
    };
    browser.cookies.onChanged.addListener(onChanged);
    // Under a path of their own, so the coverage page's own cookie checks never see them.
    const url = 'http://127.0.0.1:8843/extension-cookies/';
    const set = await browser.cookies.set({ url, name: 'extension-cookie', value: 'one', httpOnly: true, expirationDate: Date.now() / 1000 + 3600 });
    const sent = (await (await fetch('http://127.0.0.1:8843/extension-cookies/echo')).json()).cookie || '';
    // WebKit's cookie store keeps a stored HttpOnly cookie from being replaced by one without the flag.
    const overwritten = await browser.cookies.set({ url, name: 'extension-cookie', value: 'two', httpOnly: true });
    const unflagged = await browser.cookies.set({ url, name: 'extension-cookie', value: 'three' });
    const got = await browser.cookies.get({ url, name: 'extension-cookie' });
    await browser.cookies.set({ url, name: 'plain-cookie', value: 'first' });
    const plainOverwritten = await browser.cookies.set({ url, name: 'plain-cookie', value: 'second' });
    await browser.cookies.remove({ url, name: 'plain-cookie' });
    const all = await browser.cookies.getAll({ domain: '127.0.0.1', name: 'extension-cookie' });
    const stores = await browser.cookies.getAllCookieStores();
    const removed = await browser.cookies.remove({ url, name: 'extension-cookie' });
    const afterRemove = await browser.cookies.get({ url, name: 'extension-cookie' });
    await new Promise(resolve => setTimeout(resolve, 1500));
    browser.cookies.onChanged.removeListener(onChanged);
    return {
        set: set && { name: set.name, value: set.value, domain: set.domain, hostOnly: set.hostOnly, httpOnly: set.httpOnly, session: set.session, storeId: set.storeId, hasExpiration: typeof set.expirationDate === 'number' },
        sentWithRequest: sent.includes('extension-cookie=one'),
        overwritten: overwritten && { value: overwritten.value, httpOnly: overwritten.httpOnly, session: overwritten.session },
        unflagged: unflagged && { value: unflagged.value, httpOnly: unflagged.httpOnly },
        plainOverwritten: plainOverwritten && plainOverwritten.value,
        got: got && got.value,
        allCount: all.length,
        stores: stores.map(store => store.id),
        removed,
        afterRemove,
        changes,
    };
}

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
// Runs a clipboard sequence while no other test extension context uses the general pasteboard.
const withClipboardLock = async sequence => {
    await fetch('http://127.0.0.1:8843/clipboard-lock');
    try {
        return await sequence();
    } finally {
        await fetch('http://127.0.0.1:8843/clipboard-unlock');
    }
};

withClipboardLock(async () => {
    const clipboard = navigator.clipboard;
    const result = {
        type: Object.prototype.toString.call(clipboard),
        writeTextLength: clipboard.writeText.length,
    };
    try {
        await fetch(`${SERVER}/report?clipboard-start=${Date.now()}`);
        const copied = `legacy-extension-clipboard-${Date.now()}`;
        result.write = await clipboard.writeText(copied);
        result.readBack = await clipboard.readText() === copied;
        result.systemPasteboard = await (await fetch(`${SERVER}/pbpaste`)).text() === copied;

        if (await clipboard.readText() === copied)
            await clipboard.writeText('');
        result.clearedUnchanged = await clipboard.readText() === '';

        await clipboard.writeText(copied);
        const external = `external-${Date.now()}`;
        await fetch(`${SERVER}/pbcopy?${encodeURIComponent(external)}`);
        if (await clipboard.readText() === copied)
            await clipboard.writeText('');
        result.keptExternal = await clipboard.readText() === external;

        result.wrongThis = await clipboard.writeText.call({}, 'x').then(() => 'resolved', error => error.name);

        // An image, as a page copies a canvas: the system pasteboard gets WebCore's re-encoded PNG.
        const canvas = document.createElement('canvas');
        canvas.width = 3;
        canvas.height = 2;
        const context = canvas.getContext('2d');
        context.fillStyle = 'rgb(255, 0, 0)';
        context.fillRect(0, 0, 3, 2);
        const png = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
        result.imageWrite = await clipboard.write([ new ClipboardItem({ 'image/png': png, 'text/plain': Promise.resolve('image-alt') }) ]);
        const pasted = await createImageBitmap(await (await fetch(`${SERVER}/pbpng`)).blob());
        context.clearRect(0, 0, 3, 2);
        context.drawImage(pasted, 0, 0);
        result.imagePasteboard = { width: pasted.width, height: pasted.height, pixel: Array.from(context.getImageData(1, 1, 1, 1).data) };
        result.imageText = await clipboard.readText();
        result.writeWrongThis = await clipboard.write.call({}, []).then(() => 'resolved', error => error.name);
        result.writeNotItems = await clipboard.write([ 'x' ]).then(() => 'resolved', error => error.name);
    } catch (error) {
        result.error = `${error.name}: ${error.message}`;
    }
    report('clipboard', result);
});

// The global page's own requests, which WebKit 1 loads in the Safari process: their details; a cancel, a
// redirect and a response header rewrite; an Origin a converted Chrome extension's server expects, for the
// page's fetch and its worker's; a synchronous request, a WebSocket and a server redirect.
const chromeOrigin = 'chrome-extension://abcdefghijklmnopabcdefghijklmnop';
browser.webRequest.onBeforeRequest.addListener(details => {
    if (details.url.includes('/res/view-'))
        report(`view-details${new URL(details.url).pathname}`, { tabId: details.tabId, frameId: details.frameId, parentFrameId: details.parentFrameId, type: details.type, initiator: details.initiator, documentUrl: details.documentUrl, requestId: typeof details.requestId });
    if (details.url.endsWith('/res/view-redirect.json'))
        return { redirectUrl: 'http://127.0.0.1:8843/res/view-redirected.json' };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking']);
browser.webRequest.onBeforeSendHeaders.addListener(details => {
    if (details.url.includes('/echo-headers?view-origin'))
        return { requestHeaders: details.requestHeaders.filter(h => h.name.toLowerCase() !== 'origin').concat({ name: 'Origin', value: chromeOrigin }) };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'requestHeaders', 'extraHeaders']);
browser.webRequest.onHeadersReceived.addListener(details => {
    if (details.url.endsWith('/res/view-headers.json'))
        return { responseHeaders: details.responseHeaders.concat({ name: 'X-View-Modified', value: 'yes' }) };
}, { urls: ['http://127.0.0.1/*'] }, ['blocking', 'responseHeaders']);
browser.webRequest.onCompleted.addListener(details => {
    if (details.url.endsWith('/res/view-allowed.json'))
        report('view-completed', { statusCode: details.statusCode, tabId: details.tabId });
}, { urls: ['http://127.0.0.1/*'] });

{
    const settle = (key, promise) => promise.then(value => report(key, value), error => report(key, { error: String(error) }));
    settle('view-allowed', fetch(`${SERVER}/res/view-allowed.json`).then(r => 'loaded:' + r.status));
    settle('view-blocked', fetch(`${SERVER}/res/blocked-view-fetch.json`).then(r => 'loaded:' + r.status));
    settle('view-redirect', fetch(`${SERVER}/res/view-redirect.json`).then(r => new URL(r.url).pathname));
    settle('view-headers', fetch(`${SERVER}/res/view-headers.json`).then(r => r.headers.get('X-View-Modified')));
    settle('view-origin', fetch(`${SERVER}/echo-headers?view-origin`).then(r => r.json()).then(h => h.origin || 'none'));
    settle('view-worker-origin', new Promise(resolve => {
        const worker = new Worker('view-worker.js');
        worker.onmessage = event => resolve(event.data);
        worker.onerror = event => resolve({ error: event.message });
    }));
    settle('view-moved-location', fetch(`${SERVER}/moved-location`).then(r => new URL(r.url).pathname));
    settle('view-websocket-blocked', new Promise(resolve => {
        const ws = new WebSocket('ws://127.0.0.1:8844/blocked-ws');
        ws.onmessage = () => resolve('message');
        ws.onclose = event => resolve('close:' + event.code);
    }));
    const xhr = new XMLHttpRequest();
    xhr.open('GET', `${SERVER}/res/view-sync.json`, false);
    try { xhr.send(); } catch { }
    report('view-sync', { status: xhr.status });
}
