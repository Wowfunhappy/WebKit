'use strict';

// Records, where the test driver reads it, whether #ad-script loaded and whether the original ran.
document.addEventListener('load', event => {
    if (event.target.id === 'ad-script')
        document.documentElement.dataset.adScript = 'loaded';
}, true);
document.addEventListener('error', event => {
    if (event.target.id === 'ad-script')
        document.documentElement.dataset.adScript = 'failed';
}, true);
document.addEventListener('DOMContentLoaded', () => {
    document.documentElement.dataset.adScriptRan = String((window.__loaded || []).includes('csp-ad.js'));
});
