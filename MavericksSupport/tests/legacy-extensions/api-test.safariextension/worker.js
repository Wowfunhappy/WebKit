'use strict';

// A worker an extension page starts reaches the extension's files from the origin's root.
fetch('/content.js').then(response => response.text()).then(text => {
    let importScriptsOk = false;
    try {
        importScripts('/classic.js');
        importScriptsOk = self.classicScriptRan === true;
    } catch { }
    postMessage({ fetchOk: text.length !== 0, importScriptsOk });
}, error => postMessage({ fetchOk: false, error: String(error) }));
