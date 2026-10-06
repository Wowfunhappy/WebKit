'use strict';

// Runs a clipboard sequence while no other test extension context uses the general pasteboard.
const withClipboardLock = async sequence => {
    await fetch('http://127.0.0.1:8843/clipboard-lock');
    try {
        return await sequence();
    } finally {
        await fetch('http://127.0.0.1:8843/clipboard-unlock');
    }
};

// A toolbar popover, which Safari hosts in a WebKit 1 view, has the extension's clipboard access too.
withClipboardLock(() => navigator.clipboard.writeText('popover-clipboard').then(() => navigator.clipboard.readText())).then(
    text => fetch(`http://127.0.0.1:8843/report?popover-clipboard=${encodeURIComponent(JSON.stringify({ text }))}`),
    error => fetch(`http://127.0.0.1:8843/report?popover-clipboard=${encodeURIComponent(JSON.stringify({ error: `${error.name}: ${error.message}` }))}`)
);
