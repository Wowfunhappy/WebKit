#!/usr/bin/env node
// Dispatch lifetime checks against the complete extension shim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../source/WebKit/Shared/LegacyExtensions/LegacyExtensionAPI.js'), 'utf8');

function context() {
    const state = { valid: true, sent: [], calls: [] };
    const global = vm.createContext({ Event, EventTarget, URL, crypto, console: { error() { } } });
    const receive = vm.runInContext(source, global)({
        isValid: () => state.valid,
        send: json => state.sent.push(JSON.parse(json)),
    }, 'host');
    return Object.assign(state, { browser: global.browser, receive: message => receive(JSON.stringify(message)) });
}

const checkpoint = () => new Promise(resolve => setImmediate(resolve));
let passed = 0;
async function run(name, test) {
    await test();
    ++passed;
    console.log('PASS', name);
}

(async () => {
    for (const throws of [false, true]) {
        for (const eventName of ['onConnect', 'onConnectExternal', 'onMessage', 'onMessageExternal']) {
            await run(`${eventName} invalidation${throws ? ' with exception' : ''}`, async () => {
                const c = context();
                const event = c.browser.runtime[eventName];
                event.addListener(() => {
                    c.calls.push('first');
                    c.valid = false;
                    if (throws) throw new Error('listener error');
                });
                event.addListener(() => c.calls.push('second'));
                c.receive(eventName.startsWith('onConnect')
                    ? { t: 'connect', portId: 'port', name: 'test', external: eventName.endsWith('External') }
                    : { t: 'message', msgId: 'message', msg: {}, sender: {}, external: eventName.endsWith('External') });
                assert.deepEqual(c.calls, ['first']);
            });
        }
    }
    for (const kind of ['webRequest', 'proxy']) {
        for (const mode of ['return', 'throw', 'pending', 'await', 'reject']) {
            await run(`${kind} ${mode} preserves merged response`, async () => {
                const c = context();
                const event = kind === 'webRequest' ? c.browser.webRequest.onBeforeRequest : c.browser.proxy.onRequest;
                const options = kind === 'webRequest' ? ['blocking'] : [];
                event.addListener(() => kind === 'webRequest' ? { cancel: true } : { type: 'direct' }, { urls: ['<all_urls>'] }, options);
                event.addListener(() => {
                    c.calls.push('invalidate');
                    if (mode === 'await' || mode === 'reject') {
                        return Promise.resolve().then(() => {
                            c.valid = false;
                            if (mode === 'reject') throw new Error('async listener error');
                        });
                    }
                    c.valid = false;
                    if (mode === 'throw') throw new Error('listener error');
                    if (mode === 'pending') return new Promise(() => { });
                }, { urls: ['<all_urls>'] }, options);
                event.addListener(() => c.calls.push('second'), { urls: ['<all_urls>'] }, options);
                c.receive({ t: 'event', name: kind === 'webRequest' ? 'webRequest.onBeforeRequest' : 'proxy.onRequest', args: [{ url: 'http://127.0.0.1/fixture', type: 'xmlhttprequest' }], token: 42 });
                await checkpoint();
                assert.deepEqual(c.calls, ['invalidate']);
                assert.deepEqual(c.sent.filter(x => x.t === 'respond'), [{ t: 'respond', token: 42, result: kind === 'webRequest' ? { cancel: true } : { proxy: [[{ type: 'direct' }]] } }]);
            });
        }
    }
    await run('webRequest rejected thenable contributes no verdict', async () => {
        const c = context();
        c.browser.webRequest.onBeforeRequest.addListener(() => ({ cancel: true, redirectUrl: 'http://127.0.0.1/other', then: (resolve, reject) => reject(new Error('rejected')) }), { urls: ['<all_urls>'] }, ['blocking']);
        c.browser.webRequest.onBeforeRequest.addListener(() => c.calls.push('second'), { urls: ['<all_urls>'] }, ['blocking']);
        c.receive({ t: 'event', name: 'webRequest.onBeforeRequest', args: [{ url: 'http://127.0.0.1/fixture', type: 'xmlhttprequest' }], token: 45 });
        await checkpoint();
        assert.deepEqual(c.calls, ['second']);
        assert.deepEqual(c.sent.filter(x => x.t === 'respond'), [{ t: 'respond', token: 45, result: {} }]);
    });
    await run('asyncBlocking invalidation without callback answers', async () => {
        const c = context();
        c.browser.webRequest.onAuthRequired.addListener(() => { c.valid = false; }, { urls: ['<all_urls>'] }, ['asyncBlocking']);
        c.receive({ t: 'event', name: 'webRequest.onAuthRequired', args: [{ url: 'http://127.0.0.1/auth' }], token: 43 });
        await checkpoint();
        assert.deepEqual(c.sent.filter(x => x.t === 'respond'), [{ t: 'respond', token: 43, result: {} }]);
    });
    await run('proxy error listener invalidation stops dispatch', async () => {
        const c = context();
        c.browser.proxy.onError.addListener(() => { c.valid = false; });
        c.browser.proxy.onError.addListener(() => c.calls.push('second error'));
        c.browser.proxy.onRequest.addListener(() => { throw new Error('route error'); }, { urls: ['<all_urls>'] });
        c.browser.proxy.onRequest.addListener(() => c.calls.push('second request'), { urls: ['<all_urls>'] });
        c.receive({ t: 'event', name: 'proxy.onRequest', args: [{ url: 'http://127.0.0.1/route' }], token: 44 });
        await checkpoint();
        assert.deepEqual(c.calls, []);
        assert.deepEqual(c.sent.filter(x => x.t === 'respond'), [{ t: 'respond', token: 44, result: { proxy: [] } }]);
    });
    await run('invalid receiver drops queued messages', async () => {
        const c = context();
        c.browser.runtime.onMessage.addListener(() => c.calls.push('listener'));
        c.valid = false;
        c.receive({ t: 'message', msgId: 'queued', msg: {}, sender: {} });
        assert.deepEqual(c.calls, []);
    });
    console.log(`${passed} context validity checks passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
