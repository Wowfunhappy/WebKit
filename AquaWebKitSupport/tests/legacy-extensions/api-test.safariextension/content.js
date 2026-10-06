'use strict';

// Records what this content script sees on the page's root element, where the test driver reads it.
const note = (key, value) => {
    document.documentElement.dataset[key] = typeof value === 'string' ? value : JSON.stringify(value);
};

// A web page that frames one of the extension's own pages.
if (location.pathname === '/extension-frame.html' && window === window.top) {
    document.addEventListener('DOMContentLoaded', () => {
        const frame = document.createElement('iframe');
        frame.src = `${safari.extension.baseURI}frame.html`;
        document.body.appendChild(frame);
    });
}

if (typeof browser !== 'object') {
    note('extBrowser', 'missing');
} else {
    note('extBrowser', Object.keys(browser));
    const port = browser.runtime.connect({ name: 'api-test' });
    const background = id => {
        const element = document.getElementById(id);
        return element ? getComputedStyle(element).backgroundImage : 'missing';
    };
    port.onMessage.addListener(message => {
        note('ext' + message.what[0].toUpperCase() + message.what.slice(1), message);
        // A file's style sheet is based at the file; code's has a URL of its own, which resolves no relative URL.
        if (message.what === 'cssfile') {
            note('extCssFileBackgrounds', [ background('css-file-target'), background('css-code-target') ]);
            port.postMessage({ what: 'cssremove' });
        } else if (message.what === 'cssremove')
            note('extCssRemovedBackground', background('css-code-target'));
    });
    port.onDisconnect.addListener(() => note('extDisconnected', 'yes'));
    note('extFrameId', String(browser.runtime.getFrameId(window)));
    // A content script keeps the page's clipboard rules.
    if (window === window.top) {
        Promise.all([ navigator.clipboard.writeText('content script'), navigator.clipboard.readText(), navigator.clipboard.write([ new ClipboardItem({ 'text/plain': 'content script' }) ]) ].map(promise => promise.then(() => 'resolved', error => error.name))).then(
            outcomes => note('extClipboard', outcomes)
        );
    }
    port.postMessage({ what: 'hello', frameId: browser.runtime.getFrameId(window) });
    if (window === window.top) {
        port.postMessage({ what: 'css' });
        port.postMessage({ what: 'cssfile' });
        port.postMessage({ what: 'exec' });
        port.postMessage({ what: 'frames' });
        document.addEventListener('DOMContentLoaded', () => {
            const blank = document.getElementById('blank-frame');
            if (blank)
                port.postMessage({ what: 'aboutblank', blankFrameId: browser.runtime.getFrameId(blank) });
        });
        browser.runtime.sendMessage({ one: 'shot' }).then(response => note('extSendMessage', response));
        browser.runtime.sendMessage({ what: 'cookies' }).then(response => note('extCookies', response), error => note('extCookies', { error: error.message }));
    }

    // An inline script this world inserts runs in the page even where the page's CSP forbids inline scripts.
    const script = document.createElement('script');
    script.textContent = 'document.documentElement.dataset.mainWorld = "ran"';
    (document.head || document.documentElement).appendChild(script);
    script.remove();

    document.addEventListener('DOMContentLoaded', () => {
        const host = document.getElementById('host');
        if (!host)
            return;
        const root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = '<span>closed</span>';
        note('extClosedShadowRoot', browser.dom.openOrClosedShadowRoot(host) === root ? 'reachable' : 'unreachable');
    });
}

// What survives Safari's context-menu user info, which the global page reports.
if (typeof safari === 'object' && safari.self && safari.self.tab) {
    window.addEventListener('contextmenu', event => {
        safari.self.tab.setContextMenuEventUserInfo(event, { number: 0, fraction: 1.5, flag: true, text: 's', list: [ 1, 'a' ], nested: { n: 2 } });
    }, true);
}
