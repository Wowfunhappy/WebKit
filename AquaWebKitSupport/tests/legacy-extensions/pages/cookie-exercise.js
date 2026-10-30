async function cookieExercise(options) {
    const results = [];
    const base = options.base;
    const id = options.id;
    async function record(kind, operation) {
        try { results.push({kind, value: await operation()}); }
        catch (error) { results.push({kind, error: String(error)}); }
    }
    const url = kind => base + '/echo?id=' + encodeURIComponent(id + '-' + kind);
    for (const credentials of ['include', 'omit', 'same-origin'])
        await record('fetch-' + credentials, () => fetch(url(credentials), {credentials}).then(r => r.json()));
    await record('fetch-post', () => fetch(url('post'), {method: 'POST', credentials: 'include', body: 'cookie-fixture'}).then(r => r.json()));
    for (const credentials of [true, false])
        await record('xhr-' + credentials, () => new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', url('xhr-' + credentials));
            xhr.withCredentials = credentials;
            xhr.timeout = 5000;
            xhr.onload = () => { try { resolve(JSON.parse(xhr.responseText)); } catch(e) { reject(e); } };
            xhr.onerror = () => reject('XHR network error');
            xhr.ontimeout = () => reject('XHR timeout');
            xhr.send();
        }));
    await record('websocket', () => new Promise((resolve, reject) => {
        const socket = new WebSocket(base.replace(/^http/, 'ws') + '/ws?id=' + encodeURIComponent(id));
        const timer = setTimeout(() => { socket.close(); reject('WebSocket timeout'); }, 5000);
        socket.onmessage = event => { clearTimeout(timer); resolve(JSON.parse(event.data)); socket.close(); };
        socket.onerror = () => { clearTimeout(timer); reject('WebSocket network error'); };
    }));
    if (options.redirects) {
        const other = base.replace('localhost', '127.0.0.1');
        const echo = base + '/echo?id=' + encodeURIComponent(id + '-redirect-end');
        const redirect = (host, target) => host + '/redirect?id=' + encodeURIComponent(id) + '&to=' + encodeURIComponent(target);
        for (const [kind, target] of [
            ['allowed-allowed', redirect(base, echo)],
            ['allowed-denied', redirect(base, other + '/echo?id=' + encodeURIComponent(id + '-denied'))],
            ['denied-allowed', redirect(other, echo)],
            ['allowed-denied-allowed', redirect(base, redirect(other, echo))]
        ])
            await record(kind, () => fetch(target, {credentials: 'include'}).then(r => r.json()));
    }
    if (options.seed)
        await record('seed', () => fetch(base + '/seed?prefix=' + encodeURIComponent(options.seed), {credentials: 'include'}).then(r => r.json()));
    if (typeof browser !== 'undefined')
        await record('metadata', () => browser.cookies.getAll({url: base + '/'}).then(cookies => cookies.filter(c => c.name.startsWith('extck_'))));
    const domCookies = typeof document === 'undefined' ? null : document.cookie.split(/; */).filter(c => c.startsWith('extck_')).map(c => c.split('=')[0]).sort();
    return {id, base, origin: location.origin, href: location.href, domCookies, results};
}
if (typeof document !== 'undefined') {
    addEventListener('message', async event => {
        if (!event.data || event.data.cookieTest !== 'exercise') return;
        const result = await cookieExercise(event.data.options);
        event.source.postMessage({cookieResult: result}, '*');
    });
}

function cookieWorker(options, shared) {
    return new Promise((resolve, reject) => {
        const worker = shared ? new SharedWorker('shared-worker.js') : new Worker('worker.js');
        const port = shared ? worker.port : worker;
        const timer = setTimeout(() => { if (!shared) worker.terminate(); reject('Worker timeout'); }, 10000);
        port.onmessage = event => { clearTimeout(timer); if (!shared) worker.terminate(); resolve(event.data); };
        worker.onerror = event => { clearTimeout(timer); reject('Worker: ' + event.message); };
        if (shared) port.start();
        port.postMessage(options);
    });
}

async function cookieParentNavigation(options) {
    const frame = document.createElement('iframe');
    const initialURL = options.initialURL || 'http://' + (options.initialHost || '127.0.0.1') + ':8877/cookie-frame.html?id=' + encodeURIComponent(options.id + '-initial');
    let listener;
    let timer;
    try {
        await new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error('Initial child navigation timed out')), 15000);
            frame.onload = () => { clearTimeout(timer); resolve(); };
            frame.src = initialURL;
            document.body.appendChild(frame);
        });
        frame.onload = null;
        const target = 'http://' + (options.targetHost || 'localhost') + ':8877/navigation-echo?id=' + encodeURIComponent(options.id);
        const result = await new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error('Parent navigation timed out')), 15000);
            listener = event => {
                if (event.source === frame.contentWindow && event.data && event.data.cookieNavigation
                    && event.data.cookieNavigation.id === options.id) {
                    clearTimeout(timer);
                    resolve(event.data.cookieNavigation);
                }
            };
            addEventListener('message', listener);
            frame.src = target;
        });
        return {parent: location.href, initialURL, target, initialLoaded: true, result};
    } finally {
        clearTimeout(timer);
        if (listener) removeEventListener('message', listener);
        frame.remove();
    }
}

async function cookieResponseRedirect(options) {
    if (options.kind === 'ping') {
        if (options.pingTransport === 'hyperlink') {
            const sink = document.createElement('iframe');
            sink.name = 'cookie-ping-' + Date.now() + '-' + Math.random();
            sink.hidden = true;
            document.body.appendChild(sink);
            const anchor = document.createElement('a');
            anchor.href = 'about:blank';
            anchor.target = sink.name;
            anchor.ping = options.url;
            document.body.appendChild(anchor);
            anchor.click();
            anchor.remove();
            setTimeout(() => sink.remove(), 1000);
            return {queued: true, transport: 'hyperlink'};
        }
        return {queued: navigator.sendBeacon(options.url, ''), transport: 'beacon'};
    }
    return fetch(options.url, {credentials: 'include'}).then(response => response.json());
}

function cookieWebSocketProbe(options) {
    return new Promise(resolve => {
        const result = {url: options.url, opened: false, error: false, messages: []};
        const socket = new WebSocket(options.url, options.protocol || []);
        window.cookieProbeSocket = socket;
        const timer = setTimeout(() => {
            result.timeout = true;
            socket.close();
            resolve(result);
        }, 10000);
        socket.onopen = () => { result.opened = true; };
        socket.onerror = () => { result.error = true; };
        socket.onmessage = event => { result.messages.push(JSON.parse(event.data)); };
        socket.onclose = event => {
            clearTimeout(timer);
            result.code = event.code;
            result.wasClean = event.wasClean;
            resolve(result);
        };
    });
}
