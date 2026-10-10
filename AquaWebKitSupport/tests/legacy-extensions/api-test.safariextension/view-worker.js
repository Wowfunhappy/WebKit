'use strict';

// A global page's worker: its fetch carries the Origin the extension's listener sets.
fetch('http://127.0.0.1:8843/echo-headers?view-origin-worker').then(r => r.json()).then(
    headers => postMessage(headers.origin || 'none'),
    error => postMessage({ error: String(error) }));
