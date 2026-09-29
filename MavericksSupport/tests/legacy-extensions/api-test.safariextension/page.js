'use strict';

const report = (key, value) => {
    fetch(`http://127.0.0.1:8843/report?${encodeURIComponent(key)}=${encodeURIComponent(JSON.stringify(value))}`).catch(() => {});
};

// First load: follow a root-relative link. Second load: report where it landed, start a worker, open a
// port, then navigate the tab to a web page, which swaps its process.
if (location.search === '')
    document.getElementById('root-link').click();
else {
    report('page-url', { url: document.URL });
    const reader = new FileReader();
    reader.onload = () => report('page-filereader', { ok: true, result: reader.result });
    reader.onerror = () => report('page-filereader', { ok: false, error: String(reader.error) });
    reader.readAsDataURL(new Blob([ 'x' ], { type: 'text/plain' }));
    const worker = new Worker('worker.js');
    worker.onmessage = event => report('page-worker', event.data);
    browser.runtime.connect({ name: 'page-port' });
    browser.runtime.sendMessage({ what: 'page-tab' }).then(response => report('page-reply', response));
    // An extension page in a tab has the extension's clipboard access, with no gesture.
    navigator.clipboard.writeText('page-clipboard').then(() => navigator.clipboard.readText()).then(
        text => report('page-clipboard', { text }),
        error => report('page-clipboard', { error: error.name })
    );
    setTimeout(() => { location.href = 'http://127.0.0.1:8843/coverage.html?from-extension-page'; }, 8000);
}
