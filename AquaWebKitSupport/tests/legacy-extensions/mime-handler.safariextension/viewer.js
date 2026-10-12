'use strict';

// Reads the document's stream as a PDF viewer does, and reports what it read to the test server.
const report = (what, value) => fetch(`http://127.0.0.1:8843/report?${what}=${encodeURIComponent(JSON.stringify(value))}`);

browser.mimeHandler.getStreamInfo().then(async info => {
    const response = await fetch(info.streamUrl);
    const buffer = await response.arrayBuffer();
    const result = {
        info: Object.assign({}, info, { streamUrl: info.streamUrl.slice(0, 5) }),
        length: buffer.byteLength,
        signature: String.fromCharCode(...new Uint8Array(buffer, 0, Math.min(5, buffer.byteLength))),
        same: JSON.stringify(await browser.mimeHandler.getStreamInfo()) === JSON.stringify(info),
    };
    document.getElementById('result').textContent = JSON.stringify(result);
    report(info.embedded ? 'embeddedViewer' : 'viewer', result);
}, error => report('viewer', { error: error.message }));

document.getElementById('fallback').addEventListener('click', () => browser.mimeHandler.abortAndFallbackToNativeHandler());
