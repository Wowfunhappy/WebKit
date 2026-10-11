'use strict';

// Rewrites the main-frame responses of the test server's /inline/ paths, as a viewer extension does: PDFs
// open in viewer.html, application/octet-stream shows as text, and /inline/force-download.html downloads.
const header = (headers, name) => headers.find(field => field.name.toLowerCase() === name);
const replacing = (headers, name, value) => headers.filter(field => field.name.toLowerCase() !== name.toLowerCase()).concat({ name, value });

browser.webRequest.onHeadersReceived.addListener(details => {
    const contentType = ((header(details.responseHeaders, 'content-type') || {}).value || '').split(';')[0].trim().toLowerCase();
    if (details.method === 'GET' && contentType === 'application/pdf')
        return { redirectUrl: `${safari.extension.baseURI}viewer.html?file=${encodeURIComponent(details.url)}` };
    if (contentType === 'application/octet-stream')
        return { responseHeaders: replacing(details.responseHeaders, 'Content-Type', 'text/plain') };
    if (details.url.includes('force-download'))
        return { responseHeaders: replacing(details.responseHeaders, 'Content-Disposition', 'attachment; filename="forced.html"') };
}, { urls: ['http://127.0.0.1:8843/inline/*'], types: ['main_frame'] }, ['blocking', 'responseHeaders']);

// The same read viewer.html makes, from this WebKit 1 global page, for the viewer to show beside its own.
const readFile = url => fetch(url, { credentials: 'include' }).then(response => response.arrayBuffer().then(buffer => ({
    status: response.status,
    length: buffer.byteLength,
    signature: String.fromCharCode(...new Uint8Array(buffer, 0, Math.min(5, buffer.byteLength))),
})), error => ({ error: error.message }));
browser.runtime.onMessage.addListener(message => message && message.read ? readFile(message.read) : undefined);
