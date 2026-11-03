'use strict';
window.__results = { done: false };
const R = window.__results;
const root = document.documentElement;
const clip = text => text.trim().slice(0, 40);
const tryFetch = url => fetch(url).then(async response => `ok:${clip(await response.text())}`, () => 'fail');
const tryXHR = (url, async) => new Promise(resolve => {
    try {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', url, async);
        xhr.onload = () => resolve(`ok:${clip(xhr.responseText)}`);
        xhr.onerror = () => resolve('fail');
        xhr.send();
        if (!async)
            resolve(`ok:${clip(xhr.responseText)}`);
    } catch (error) {
        resolve('fail');
    }
});
const tryImage = (url, crossOrigin) => new Promise(resolve => {
    const image = new Image();
    if (crossOrigin)
        image.crossOrigin = 'anonymous';
    image.onload = () => {
        const canvas = document.createElement('canvas');
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        const context = canvas.getContext('2d');
        context.drawImage(image, 0, 0);
        try {
            context.getImageData(0, 0, 1, 1);
            resolve('pixels');
        } catch (error) {
            resolve('tainted');
        }
    };
    image.onerror = () => resolve('fail');
    image.src = url;
});
const tryScript = url => new Promise(resolve => {
    const script = document.createElement('script');
    script.onload = () => resolve('ran');
    script.onerror = () => resolve('fail');
    script.src = url;
    document.head.append(script);
});
const tryStyle = url => new Promise(resolve => {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.onload = () => {
        try {
            resolve(`rules:${link.sheet.cssRules.length}`);
        } catch (error) {
            resolve('rules-blocked');
        }
    };
    link.onerror = () => resolve('fail');
    link.href = url;
    document.head.append(link);
});
const tryImport = url => import(url).then(module => `ok:${module.value}`, () => 'fail');
const frameMessages = [];
window.addEventListener('message', event => {
    if (event.data && event.data.raFrame)
        frameMessages.push(event.data);
});
const tryFrame = url => new Promise(resolve => {
    const before = frameMessages.length;
    const frame = document.createElement('iframe');
    frame.src = url;
    document.body.append(frame);
    setTimeout(() => {
        frame.remove();
        resolve(frameMessages.length > before ? 'loaded' : 'blocked');
    }, 1000);
});
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const attribute = async name => {
    for (let i = 0; i < 200 && !root.hasAttribute(`data-${name}`); ++i)
        await wait(50);
    return root.getAttribute(`data-${name}`);
};
const timelineURLs = () => performance.getEntriesByType('resource').map(entry => entry.name).filter(name => name.startsWith('safari-extension:'));
const everyRead = async base => ({
    fetch: await tryFetch(`${base}.txt`),
    asyncXHR: await tryXHR(`${base}.txt`, true),
    syncXHR: await tryXHR(`${base}.txt`, false),
    image: await tryImage(`${base}.png`),
    imageCORS: await tryImage(`${base}.png`, true),
});
(async () => {
    const extensionRoot = await attribute('root');
    R.root = extensionRoot;
    R.privateBefore = await everyRead(`${extensionRoot}private`);
    R.privateScript = await tryScript(`${extensionRoot}private.js`);
    R.privateStyle = await tryStyle(`${extensionRoot}private.css`);
    R.privateImport = await tryImport(`${extensionRoot}private-module.js`);
    R.privateFrame = await tryFrame(`${extensionRoot}private-frame.html`);
    R.privateNoReadViaOpen = typeof window.__privateScriptRan;
    R.declared = await tryFetch(`${extensionRoot}declared/open.txt`);
    R.declaredDenied = await tryFetch(`${extensionRoot}declared/denied.txt`);
    R.denied = await tryFetch(`${extensionRoot}denied/secret.txt`);
    R.deniedImage = await tryImage(`${extensionRoot}denied/secret.png`);
    R.serverRedirectFetch = await tryFetch(`/to-url?to=${encodeURIComponent(`${extensionRoot}private.txt`)}`);
    R.serverRedirectXHR = await tryXHR(`/to-url?to=${encodeURIComponent(`${extensionRoot}private.txt`)}`, true);
    R.serverRedirectSyncXHR = await tryXHR(`/to-url?to=${encodeURIComponent(`${extensionRoot}private.txt`)}`, false);
    R.serverRedirectImage = await tryImage(`/to-url?to=${encodeURIComponent(`${extensionRoot}private.png`)}`);
    R.serverRedirectFrame = await tryFrame(`/to-url?to=${encodeURIComponent(`${extensionRoot}private-frame.html`)}`);

    const base = document.createElement('base');
    base.href = extensionRoot;
    document.head.append(base);
    R.baseResolved = document.baseURI.startsWith('safari-extension:');
    R.baseImport = await new Promise(resolve => {
        window.__baseImportDone = resolve;
        const inline = document.createElement('script');
        inline.textContent = `import('./private-module.js').then(module => window.__baseImportDone('ok:' + module.value), () => window.__baseImportDone('fail'));`;
        document.head.append(inline);
    });
    base.remove();

    window.dispatchEvent(new Event('ra-own-reads'));
    R.own = JSON.parse(await attribute('own'));
    R.timelineAfterOwnReads = timelineURLs();
    R.privateAfterOwnReads = await tryFetch(`${extensionRoot}private.txt`);

    window.dispatchEvent(new Event('ra-expose'));
    R.exposedByContent = JSON.parse(await attribute('exposed'));
    R.scriptRan = typeof window.__exposedScriptRan;
    await wait(1000);
    R.exposedFrame = frameMessages.find(message => message.raFrame === 'frame.html') || null;
    R.exposedFetch = await tryFetch(`${extensionRoot}exposed.js`);
    R.exposedImage = await tryImage(`${extensionRoot}exposed.png`);
    R.exposedStyle = await tryStyle(`${extensionRoot}exposed.css`);
    R.exposedImport = await tryImport(`${extensionRoot}exposed-module.js`);
    R.siblingStaysPrivate = await tryFetch(`${extensionRoot}private.txt`);
    R.deniedStillBlocked = await tryImage(`${extensionRoot}denied/placed.png`);

    const planted = document.createElement('div');
    planted.id = 'ra-planted';
    planted.hidden = true;
    planted.innerHTML = `<img data-keep src="" data-x="${extensionRoot}r3-clone-data.txt"><div data-y="${extensionRoot}r3-import.txt" style="background-image:url('${extensionRoot}r2-clone.txt')"></div><a href="${extensionRoot}r3-clone-src.txt"></a><a href="${extensionRoot}r3-range.txt"></a><a href="${extensionRoot}r3-domparser.txt"></a><template><a href="${extensionRoot}r3-template.txt"></a></template>`;
    document.body.append(planted);
    const plantedStyle = document.createElement('style');
    plantedStyle.id = 'ra-planted-style';
    plantedStyle.textContent = `.ra-reinsert { background-image: url('${extensionRoot}r2-reinsert.txt'); }`;
    document.head.append(plantedStyle);
    document.documentElement.style.setProperty('--ra-var', `url("${extensionRoot}r1-var.txt")`);
    document.documentElement.style.setProperty('--ra-sheet-var', `url("${extensionRoot}r1-sheet-var.txt")`);
    const pageVar = document.querySelector('.ra-page-var');
    pageVar.style.setProperty('--ra-page', `url("${extensionRoot}r2-var.txt")`);
    pageVar.style.backgroundImage = 'var(--ra-page)';
    getComputedStyle(document.querySelector('.ra-injected-var')).backgroundImage;
    getComputedStyle(document.querySelector('.ra-sheet-var')).backgroundImage;
    window.dispatchEvent(new Event('ra-read-planted'));
    await attribute('readPlanted');

    const readableRules = sheet => {
        try {
            return !!sheet.cssRules;
        } catch (error) {
            return false;
        }
    };
    const exposedLink = [...document.styleSheets].find(sheet => sheet.href && sheet.href.endsWith('exposed.css') && readableRules(sheet));
    R.foundExposedSheet = !!exposedLink;
    const attemptStep = step => {
        try {
            step();
            return 'ran';
        } catch (error) {
            return `threw:${error.name}`;
        }
    };
    if (exposedLink) {
        R.insertRuleStep = attemptStep(() => exposedLink.insertRule(`.ra-cssom { background-image: url(r1-insert.txt); }`, 0));
        R.ruleStyleStep = attemptStep(() => {
            const rule = [...exposedLink.cssRules].find(candidate => candidate.selectorText === '.ra-sheet');
            rule.style.backgroundImage = 'url(r1-style.txt)';
        });
        R.insertImportStep = attemptStep(() => exposedLink.insertRule('@import url(r5-page-import.txt);', 0));
    }
    const plantedRead = {};
    for (const file of ['r1-insert', 'r1-style', 'r1-var', 'r1-sheet-var', 'r2-var', 'r2-clone', 'r2-reinsert', 'r3-clone-src', 'r3-clone-data', 'r3-import', 'r3-range', 'r3-domparser', 'r3-template', 'r5-page-import'])
        plantedRead[file] = await tryFetch(`${extensionRoot}${file}.txt`);
    R.plantedRead = plantedRead;

    R.importedFetch = await tryFetch(`${extensionRoot}sub/imported.css`);
    R.injectedImportedFetch = await tryFetch(`${extensionRoot}sub/injected-imported.css`);

    R.hostCaseDenied = await tryFetch(`${extensionRoot.replace(/^safari-extension:\/\/[^/]+/, match => match.toLowerCase())}declared/denied.txt`);
    const encoded = {};
    for (const path of ['declared/de%E2%80%8Cnied.txt', 'declared/denied.txt%E2%80%8C', 'declared/denied%EF%BB%BF.txt', 'declared/de%E2%80%8Dnied.txt', 'declared/den%E2%80%8Eied.txt', 'denied/secr%E2%80%AAet.txt', 'denied/SECRET.TXT', 'denied/secre%74.txt', 'DENIED/secret.txt', 'declared/DENIED.txt', 'declared/deni%65d.txt', 'declared/..%2fprivate.txt', 'declared/..%2Fdenied/secret.txt', 'declared/x%2f..%2f..%2fprivate.txt', 'declared/%2e%2e/private.txt', 'declared/..%5cprivate.txt', 'declared/..%252fprivate.txt'])
        encoded[path] = await tryFetch(`${extensionRoot}${path}`);
    R.encodedPaths = encoded;

    window.dispatchEvent(new Event('ra-under-exposure'));
    await attribute('underExposure');
    await wait(500);
    const under = {};
    for (const file of ['under-srcset-a.png', 'under-srcset-b.png', 'under-upper.png', 'under-space.png', 'under-css.txt', 'under-style.txt', 'r3-data.txt', 'under-innerhtml-style.txt', 'under-template.png', 'under-sheet-var.png', 'under-sheet-custom.png'])
        under[file] = (await tryFetch(`${extensionRoot}${file}`)).startsWith('ok') ? 'readable' : 'blocked';
    R.underExposure = under;

    R.syncRedirectDenied = await tryXHR('/ra-redirect-denied.txt', false);
    R.asyncRedirectDenied = await tryXHR('/ra-redirect-denied.txt', true);
    R.syncCrossRedirect = await tryXHR(`/ra-cross-redirect.png?to=${encodeURIComponent(`${extensionRoot}private.txt`)}`, false);
    R.serverRedirectExposedImage = await tryImage(`/to-url?to=${encodeURIComponent(`${extensionRoot}exposed.png`)}`);
    R.redirectedFrame = await new Promise(resolve => {
        const listener = event => {
            if (!event.data || !event.data.raRedirectedFrame)
                return;
            window.removeEventListener('message', listener);
            resolve(`${event.data.raRedirectedFrame} ${event.data.width}`);
        };
        window.addEventListener('message', listener);
        const frame = document.createElement('iframe');
        frame.src = '/ra-redirect-frame.html';
        document.body.append(frame);
        setTimeout(() => resolve('timeout'), 4000);
    });
    const framedDocument = url => new Promise(resolve => {
        const frame = document.createElement('iframe');
        const finish = value => {
            window.removeEventListener('message', listener);
            frame.remove();
            resolve(value);
        };
        const listener = event => {
            if (!event.data)
                return;
            if (event.data.raTarget)
                finish(`${event.data.raTarget} ${event.data.origin}`);
            else if (event.data.raRedirectedFrame)
                finish(`${event.data.raRedirectedFrame} ${event.data.width}`);
            else if (event.data.raLeak)
                finish(`leaked ${event.data.raLeak}`);
        };
        window.addEventListener('message', listener);
        frame.src = url;
        document.body.append(frame);
        setTimeout(() => finish('timeout'), 2500);
    });
    R.frameToHTTP = await framedDocument('/ra-fr-to-http.html');
    R.frameToHTTPWithPolicy = await framedDocument('/ra-fr-to-http-coep.html');
    R.frameToData = await framedDocument('/ra-fr-to-data.html');
    R.frameAfterServerRedirect = await framedDocument(`/to-url?to=${encodeURIComponent('http://127.0.0.1:8843/ra-fr-after-server.html')}`);
    R.frameHeaderVerdict = await framedDocument('/ra-fr-header-verdict.html');
    R.syncOwnPrivate = await tryXHR('/ra-redirect-private-sync.txt', false);

    R.dnrControlFrame = await framedDocument('/ra-dnr-control-frame.html');
    R.dnrControlPathFrame = await framedDocument('/ra-dnr-control-path-frame.html');
    R.frameSubresources = await framedDocument('/ra-frame-sub.html');
    R.dnrRegexDeniedAsync = await tryXHR('/ra-dnr-regex-denied.txt', true);
    R.dnrRegexDeniedSync = await tryXHR('/ra-dnr-regex-denied.txt', false);
    R.dnrRegexDeniedFrame = await framedDocument('/ra-dnr-regex-denied-frame.html');
    R.dnrTransformDeniedAsync = await tryXHR('/ra-dnr-transform-denied.txt', true);
    R.dnrTransformDeniedSync = await tryXHR('/ra-dnr-transform-denied.txt', false);
    R.dnrTransformDeniedFrame = await framedDocument('/ra-dnr-transform-denied-frame.html');
    const otherRoot = await (await fetch('/other-root')).text();
    R.otherRootKnown = otherRoot.startsWith('safari-extension:');
    root.setAttribute('data-other-root', otherRoot);
    window.dispatchEvent(new Event('ra-cross-rules'));
    R.crossRules = JSON.parse(await attribute('crossRules'));
    await wait(1500);
    R.dnrRegexCrossAsync = await tryXHR('/ra-dnr-regex-cross.txt', true);
    R.dnrRegexCrossSync = await tryXHR('/ra-dnr-regex-cross.txt', false);
    R.dnrRegexCrossFrame = await framedDocument('/ra-dnr-regex-cross-frame.html');
    R.dnrTransformCrossAsync = await tryXHR('/ra-dnr-transform-cross.txt', true);
    R.dnrTransformCrossSync = await tryXHR('/ra-dnr-transform-cross.txt', false);
    R.dnrTransformCrossFrame = await framedDocument('/ra-dnr-transform-cross-frame.html');
    R.dnrCaptureCrossAsync = await tryXHR(`/ra-dnr-capture?to=${otherRoot}file-one.js`, true);
    R.dnrCaptureCrossFrame = await framedDocument(`/ra-dnr-capture?to=${otherRoot}leak-frame.html`);
    R.dnrCaptureOwnDenied = await tryXHR(`/ra-dnr-capture?to=${extensionRoot}declared/denied.txt`, true);

    R.dnrDeniedAsync = await tryXHR('/ra-dnr-denied.txt', true);
    R.dnrDeniedSync = await tryXHR('/ra-dnr-denied.txt', false);
    await tryImage('/ra-dnr-star.png');
    R.dnrStarWildcard = await tryFetch(`${extensionRoot}starfile.png`);
    R.dnrStale = await tryFetch(`${extensionRoot}dnr-stale.png`);
    R.dnrStatic = await tryImage('/ra-dnr-me.png');
    R.dnrDynamic = await tryImage('/ra-dnr-dyn.png');
    R.crossRedirect = await tryImage(`/ra-cross-redirect.png?to=${encodeURIComponent(`${extensionRoot}r13-private.txt`)}`);
    R.crossRedirectRead = await tryFetch(`${extensionRoot}r13-private.txt`);
    R.starHostRead = await tryImage(`/ra-cross-redirect.png?to=${encodeURIComponent(`${extensionRoot.replace(/^safari-extension:\/\/[^/]+/, 'safari-extension://*')}r13-private.txt`)}`);
    R.starHostAfter = await tryFetch(`${extensionRoot}r13-private.txt`);

    R.extensionRedirect = await tryImage('/ra-redirect-me.png');
    const probe = document.querySelector('.ra-injected');
    probe.style.display = 'block';
    getComputedStyle(probe).backgroundImage;
    const styled = document.createElement('div');
    styled.className = 'ra-sheet';
    document.body.append(styled);
    getComputedStyle(styled).backgroundImage;
    await wait(1000);
    window.dispatchEvent(new Event('ra-loaded'));
    R.loaded = JSON.parse(await attribute('loaded'));
    R.timelineAtEnd = timelineURLs();
})().catch(error => {
    R.pageError = `${error.name}: ${error.message}`;
}).then(() => {
    // A Web Clip has no AppleScript to read results from.
    if (location.search.includes('report'))
        fetch(`/report?resourceAccessClip=${encodeURIComponent(JSON.stringify(R))}`);
    R.done = true;
});
