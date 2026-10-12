'use strict';

// Relays pages/filter.html's requests to the global page: window.postMessage({ toExtension, id }) is answered
// with window.postMessage({ reply: id, result }).
if (window === window.top) {
    window.addEventListener('message', event => {
        if (event.source !== window || !event.data || event.data.toExtension === undefined)
            return;
        const { toExtension, id } = event.data;
        browser.runtime.sendMessage(toExtension).then(result => window.postMessage({ reply: id, result }, '*'), error => window.postMessage({ reply: id, result: { error: error.message } }, '*'));
    });
}
