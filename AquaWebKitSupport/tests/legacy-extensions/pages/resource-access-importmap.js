'use strict';
window.__results = { done: false };
const attribute = async name => {
    for (let i = 0; i < 200 && !document.documentElement.hasAttribute(`data-${name}`); ++i)
        await new Promise(resolve => setTimeout(resolve, 50));
    return document.documentElement.getAttribute(`data-${name}`);
};
(async () => {
    const extensionRoot = await attribute('root');
    const map = document.createElement('script');
    map.type = 'importmap';
    map.textContent = JSON.stringify({ imports: { [`${extensionRoot}sub/map-target.js`]: `${extensionRoot}r4-secret.js`, [`${extensionRoot}importmap-module.js`]: `${extensionRoot}r4-secret.js` } });
    document.head.append(map);
    const element = document.createElement('script');
    element.type = 'module';
    window.__results.mapped = await new Promise(resolve => {
        element.onload = () => resolve('ran');
        element.onerror = () => resolve('failed');
        element.setAttribute('src', `${extensionRoot}importmap-module.js`);
        document.head.append(element);
    });
    window.__results.secretFetch = await fetch(`${extensionRoot}r4-secret.js`).then(async response => `read:${(await response.text()).trim()}`, () => 'failed');
    window.__results.done = true;
})();
