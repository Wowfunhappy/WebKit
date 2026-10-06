'use strict';

// Records, where the test driver reads it, whether a Blob reads back through fetch and FileReader.
window.__blob = {};
fetch(URL.createObjectURL(new Blob([ 'x' ]))).then(r => r.text()).then(
    text => { window.__blob.fetch = 'ok:' + text; },
    error => { window.__blob.fetch = 'error:' + error; }
);
const reader = new FileReader();
reader.onload = () => { window.__blob.reader = 'ok:' + reader.result; };
reader.onerror = () => { window.__blob.reader = 'error:' + reader.error; };
reader.readAsText(new Blob([ 'y' ]));
