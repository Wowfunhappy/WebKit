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
