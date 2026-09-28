'use strict';

// A toolbar popover, which Safari hosts in a WebKit 1 view, has the extension's clipboard access too.
fetch('/manifest.json').then(() => navigator.clipboard.writeText('popover-clipboard')).then(() => navigator.clipboard.readText()).then(
    text => fetch(`http://127.0.0.1:8843/report?popover-clipboard=${encodeURIComponent(JSON.stringify({ text }))}`),
    error => fetch(`http://127.0.0.1:8843/report?popover-clipboard=${encodeURIComponent(JSON.stringify({ error: `${error.name}: ${error.message}` }))}`)
);
