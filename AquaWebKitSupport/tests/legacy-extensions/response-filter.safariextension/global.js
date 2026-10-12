'use strict';

// Rewrites REPLACE-ME to REPLACED in the test server's /filter/ responses as uBlock Origin's body filters do:
// collect the body, then write it changed and close. Some paths exercise the rest of StreamFilter:
// prefix.txt writes in onstart, *-count.txt appends how many data events arrived, suspend.txt suspends on its
// first chunk, disconnect.txt passes its first chunk on and disconnects, passthrough.txt and slow.txt write
// each chunk, changed, as it arrives, and held.txt, which the server lets the cache keep, holds the filter open
// for five seconds after its body ends.
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const filterErrors = [];

browser.webRequest.onHeadersReceived.addListener(details => {
    const path = new URL(details.url).pathname;
    if (path.startsWith('/filter/plain/'))
        return;
    const filter = browser.webRequest.filterResponseData(details.requestId);
    const chunks = [];
    let dataEvents = 0;
    filter.onstart = () => {
        if (path.endsWith('/prefix.txt'))
            filter.write(encoder.encode('prefix '));
    };
    filter.ondata = event => {
        ++dataEvents;
        if (path.endsWith('/disconnect.txt')) {
            filter.write(event.data);
            filter.disconnect();
            return;
        }
        if (path.endsWith('/passthrough.txt') || path.endsWith('/slow.txt')) {
            filter.write(encoder.encode(decoder.decode(event.data, { stream: true }).replaceAll('REPLACE-ME', 'REPLACED')));
            return;
        }
        chunks.push(new Uint8Array(event.data));
        if (path.endsWith('/suspend.txt') && dataEvents === 1) {
            filter.suspend();
            setTimeout(() => filter.resume(), 500);
        }
    };
    filter.onstop = () => {
        if (path.endsWith('/passthrough.txt') || path.endsWith('/slow.txt')) {
            filter.write(encoder.encode(`${decoder.decode()} (${dataEvents} data events)`));
            filter.close();
            return;
        }
        let text = chunks.map(chunk => decoder.decode(chunk, { stream: true })).join('') + decoder.decode();
        text = text.replaceAll('REPLACE-ME', 'REPLACED');
        if (path.endsWith('-count.txt'))
            text += ` (${dataEvents} data events, status ${filter.status})`;
        const end = () => {
            filter.write(encoder.encode(text));
            filter.close();
        };
        if (path.endsWith('/held.txt'))
            setTimeout(end, 5000);
        else
            end();
    };
    filter.onerror = () => filterErrors.push({ url: details.url, error: filter.error });
}, { urls: ['http://127.0.0.1:8843/filter/*', 'http://localhost:8843/filter/*'] }, ['blocking']);

// A requestId no load has fails asynchronously.
const invalid = new Promise(resolve => {
    const filter = browser.webRequest.filterResponseData('no-such-request');
    filter.onerror = () => resolve({ status: filter.status, error: filter.error });
});

browser.runtime.onMessage.addListener(message => {
    if (message.invalid)
        return invalid;
    if (message.filterErrors)
        return Promise.resolve(filterErrors);
    if (message.privacy) {
        const [area, name] = message.privacy;
        const setting = browser.privacy[area][name];
        const change = message.clear ? setting.clear({}) : message.value === undefined ? Promise.resolve() : setting.set({ value: message.value });
        return change.then(() => setting.get({}));
    }
});
