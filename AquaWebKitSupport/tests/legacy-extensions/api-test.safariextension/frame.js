'use strict';

// An extension page framed by a web page has the extension's clipboard access, with no gesture: text, then an image.
const report = (key, value) => fetch(`http://127.0.0.1:8843/report?${encodeURIComponent(key)}=${encodeURIComponent(JSON.stringify(value))}`).catch(() => {});

// Runs a clipboard sequence while no other test extension context uses the general pasteboard.
const withClipboardLock = async sequence => {
    await fetch('http://127.0.0.1:8843/clipboard-lock');
    try {
        return await sequence();
    } finally {
        await fetch('http://127.0.0.1:8843/clipboard-unlock');
    }
};

const canvas = document.createElement('canvas');
canvas.width = 5;
canvas.height = 3;
canvas.getContext('2d').fillRect(0, 0, 5, 3);
const result = {};
withClipboardLock(() => navigator.clipboard.writeText('frame-clipboard').then(() => navigator.clipboard.readText()).then(text => {
    result.text = text;
}, error => {
    result.textError = error.name;
}).then(() => new Promise(resolve => canvas.toBlob(resolve, 'image/png')))
    .then(png => navigator.clipboard.write([ new ClipboardItem({ 'image/png': png }) ]))
    .then(() => fetch('http://127.0.0.1:8843/pbpng')).then(response => response.blob()).then(createImageBitmap).then(image => {
        result.image = { width: image.width, height: image.height };
    }, error => {
        result.imageError = `${error.name}: ${error.message}`;
    })).then(() => report('frame-clipboard', result)).then(() => parent.postMessage('frame-clipboard-done', '*'));
