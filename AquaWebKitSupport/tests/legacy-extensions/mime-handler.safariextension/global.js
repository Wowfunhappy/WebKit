'use strict';

// Reports to the test server what this page, which no stream is attached to, gets from the mimeHandler API, and
// sets the handler's options when /mime-options/<enabled> loads in a tab.
const report = (what, value) => fetch(`http://127.0.0.1:8843/report?${what}=${encodeURIComponent(JSON.stringify(value))}`);

browser.mimeHandler.getStreamInfo().then(info => report('globalStreamInfo', info), error => report('globalStreamInfo', { error: error.message }));
browser.mimeHandler.getMimeHandlerOptions('application/pdf').then(options => report('globalOptions', options));

browser.webRequest.onBeforeRequest.addListener(details => {
    const enabled = details.url.endsWith('/true');
    browser.mimeHandler.setMimeHandlerOptions('application/pdf', { enabled })
        .then(() => browser.mimeHandler.getMimeHandlerOptions('application/pdf'))
        .then(options => report('options', options));
}, { urls: ['http://127.0.0.1:8843/mime-options/*'], types: ['main_frame'] });
