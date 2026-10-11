'use strict';

// Reads the PDF named by ?file= as a viewer does: a credentialed fetch from the extension's origin,
// which the server answers without CORS headers. The global page reads it too.
const file = new URLSearchParams(location.search).get('file');
const readFile = url => fetch(url, { credentials: 'include' }).then(response => response.arrayBuffer().then(buffer => ({
    status: response.status,
    length: buffer.byteLength,
    signature: String.fromCharCode(...new Uint8Array(buffer, 0, Math.min(5, buffer.byteLength))),
})), error => ({ error: error.message }));
Promise.all([readFile(file), browser.runtime.sendMessage({ read: file })]).then(([page, globalPage]) => {
    window.__result = { page, globalPage };
    document.getElementById('result').textContent = JSON.stringify(window.__result);
});
