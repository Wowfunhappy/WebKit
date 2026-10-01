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
const report = (key, value) => fetch(`http://127.0.0.1:8843/report?${encodeURIComponent(key)}=${encodeURIComponent(JSON.stringify(value))}`).catch(() => {});

// First load: follow a root-relative link. Second load: report where it landed, start a worker, open a
// port, then, once every report is in, navigate the tab to a web page, which swaps its process.
if (location.search === '')
    document.getElementById('root-link').click();
else {
    const canvas = document.createElement('canvas');
    canvas.width = 4;
    canvas.height = 4;
    canvas.getContext('2d').fillRect(0, 0, 4, 4);
    const reader = new FileReader();
    const worker = new Worker('worker.js');
    browser.runtime.connect({ name: 'page-port' });
    const reports = [
        report('page-url', { url: document.URL }),
        new Promise(resolve => {
            reader.onload = () => resolve(report('page-filereader', { ok: true, result: reader.result }));
            reader.onerror = () => resolve(report('page-filereader', { ok: false, error: String(reader.error) }));
            reader.readAsDataURL(new Blob([ 'x' ], { type: 'text/plain' }));
        }),
        new Promise(resolve => {
            worker.onmessage = event => resolve(report('page-worker', event.data));
        }),
        browser.runtime.sendMessage({ what: 'page-tab' }).then(response => report('page-reply', response)),
        // An extension page in a tab has the extension's clipboard access, with no gesture: text, then an image.
        withClipboardLock(() => navigator.clipboard.writeText('page-clipboard').then(() => navigator.clipboard.readText()).then(
            text => report('page-clipboard', { text }),
            error => report('page-clipboard', { error: error.name })
        ).then(() => new Promise(resolve => canvas.toBlob(resolve, 'image/png')))
            .then(png => navigator.clipboard.write([ new ClipboardItem({ 'image/png': png }) ]))
            .then(() => fetch('http://127.0.0.1:8843/pbpng')).then(response => response.blob()).then(createImageBitmap).then(
                image => report('page-clipboard-image', { width: image.width, height: image.height }),
                error => report('page-clipboard-image', { error: `${error.name}: ${error.message}` })
            )),
    ];
    Promise.allSettled(reports).then(() => { location.href = 'http://127.0.0.1:8843/coverage.html?from-extension-page'; });
}
