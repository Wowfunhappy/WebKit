window.wsEvents = [];
window.wsAction = {};
window.wsHeld = null;
const wsRecord = (stage, extra, d) => wsEvents.push({stage, extra, url:d.url, type:d.type,
    requestId:d.requestId, headers:d.requestHeaders || [], responseHeaders:d.responseHeaders || [],
    statusCode:d.statusCode, statusLine:d.statusLine, redirectUrl:d.redirectUrl, error:d.error});
const wsProtected = ['Host', 'Sec-WebSocket-Key', 'Sec-WebSocket-Version', 'Sec-WebSocket-Protocol',
    'Sec-WebSocket-Extensions', 'Authorization', 'Proxy-Authorization', 'Connection', 'Upgrade',
    'Content-Length', 'Transfer-Encoding', 'Pragma', 'Cache-Control', 'Proxy-Connection'];
const wsHeaderEdit = d => ({requestHeaders:d.requestHeaders.concat(wsProtected.map(name=>({name,value:'fixture-injection'})))});
window.wsBefore = d => {
    wsRecord('before', true, d);
    if (wsAction.mode === 'hop-cancel' && d.url === wsAction.cancelURL) return {cancel:true};
    if (wsAction.redirect && d.url === wsAction.url) return {redirectUrl:wsAction.redirect};
};
window.wsHeaders = d => {
    wsRecord('headers', true, d);
    if (d.url !== wsAction.url) return;
    if (wsAction.hold === 'headers') return new Promise(resolve => { wsHeld=()=>resolve(wsHeaderEdit(d)); });
    if (wsAction.mode === 'cancel') return {cancel:true};
    if (wsAction.mode === 'remove') return {requestHeaders:d.requestHeaders.filter(h=>h.name.toLowerCase()!=='cookie')};
    if (wsAction.mode === 'replace') return {requestHeaders:d.requestHeaders.filter(h=>!['cookie','x-cookie-probe'].includes(h.name.toLowerCase()))
        .concat([{name:'Cookie',value:'extck_ws_override=1'},{name:'X-Cookie-Probe',value:'handshake'}])};
    if (['protected', 'auth', 'proxy-route'].includes(wsAction.mode)) return wsHeaderEdit(d);
};
window.wsSent = d => wsRecord('sent', true, d);
window.wsPlainHeaders = d => wsRecord('headers', false, d);
window.wsPlainSent = d => wsRecord('sent', false, d);
window.wsMergeHeaders = d => {
    if (['remove', 'replace'].includes(wsAction.mode))
        return {requestHeaders:d.requestHeaders.concat([{name:'X-Cookie-Merge',value:'listener'}])};
};
window.wsReceived = d => {
    wsRecord('received', true, d);
    if (d.url !== wsAction.url) return;
    const editUpgrade = value => ({responseHeaders:d.responseHeaders.filter(h=>h.name.toLowerCase()!=='upgrade').concat([{name:'Upgrade',value}])});
    if (wsAction.hold === 'received') return new Promise(resolve => { wsHeld=()=>resolve(editUpgrade('late-invalid')); });
    if (wsAction.mode === 'response-cancel') return {cancel:true};
    if (wsAction.mode === 'response-repair') return editUpgrade('websocket');
    if (wsAction.mode === 'response-reject') return editUpgrade('invalid');
    if (wsAction.mode === 'response-redirect') return {redirectUrl:wsAction.responseRedirect};
};
window.wsRedirect = d => wsRecord('redirect', true, d);
window.wsResponse = d => wsRecord('response', true, d);
window.wsComplete = d => wsRecord('complete', true, d);
window.wsError = d => wsRecord('error', true, d);
window.wsAuth = d => {
    wsRecord('auth', true, d);
    if (wsAction.mode === 'auth-cancel') return {cancel:true};
    return {authCredentials:{username:'cookie-ws',password:'cookie-password'}};
};
window.wsProxy = d => {
    wsRecord('proxy', true, d);
    if (wsAction.mode === 'proxy-route') return {type:'http',host:'127.0.0.1',
        port:Number(new URL(d.url).searchParams.get('hop')) ? wsAction.proxyPorts[1] : wsAction.proxyPorts[0],
        proxyAuthorizationHeader:'Basic '+btoa('cookie-proxy:proxy-password')};
    return {type:'direct'};
};
window.wsFilter = {urls:['ws://localhost/*','ws://127.0.0.1/*','ws://ext-cookie.test/*',
    'wss://localhost/*','wss://127.0.0.1/*','wss://ext-cookie.test/*'],types:['websocket']};
window.wsRegisterHeaders = () => {
    browser.webRequest.onBeforeSendHeaders.addListener(wsHeaders,wsFilter,['blocking','requestHeaders','extraHeaders']);
    browser.webRequest.onBeforeSendHeaders.addListener(wsMergeHeaders,wsFilter,['blocking','requestHeaders']);
    browser.webRequest.onSendHeaders.addListener(wsSent,wsFilter,['requestHeaders','extraHeaders']);
    browser.webRequest.onBeforeSendHeaders.addListener(wsPlainHeaders,wsFilter,['requestHeaders']);
    browser.webRequest.onSendHeaders.addListener(wsPlainSent,wsFilter,['requestHeaders']);
};
window.wsRemoveHeaders = () => {
    browser.webRequest.onBeforeSendHeaders.removeListener(wsHeaders);
    browser.webRequest.onBeforeSendHeaders.removeListener(wsMergeHeaders);
    browser.webRequest.onSendHeaders.removeListener(wsSent);
    browser.webRequest.onBeforeSendHeaders.removeListener(wsPlainHeaders);
    browser.webRequest.onSendHeaders.removeListener(wsPlainSent);
};
window.wsRegister = () => {
    browser.webRequest.onBeforeRequest.addListener(wsBefore,wsFilter,['blocking']);
    wsRegisterHeaders();
    browser.webRequest.onHeadersReceived.addListener(wsReceived,wsFilter,['blocking','responseHeaders','extraHeaders']);
    browser.webRequest.onBeforeRedirect.addListener(wsRedirect,wsFilter,['responseHeaders']);
    browser.webRequest.onResponseStarted.addListener(wsResponse,wsFilter,['responseHeaders']);
    browser.webRequest.onCompleted.addListener(wsComplete,wsFilter,['responseHeaders']);
    browser.webRequest.onErrorOccurred.addListener(wsError,wsFilter);
    browser.webRequest.onAuthRequired.addListener(wsAuth,wsFilter,['blocking','responseHeaders']);
    browser.proxy.onRequest.addListener(wsProxy,wsFilter,['requestHeaders']);
};
window.wsRemove = () => {
    wsRemoveHeaders();
    browser.webRequest.onBeforeRequest.removeListener(wsBefore);
    browser.webRequest.onHeadersReceived.removeListener(wsReceived);
    browser.webRequest.onBeforeRedirect.removeListener(wsRedirect);
    browser.webRequest.onResponseStarted.removeListener(wsResponse);
    browser.webRequest.onCompleted.removeListener(wsComplete);
    browser.webRequest.onErrorOccurred.removeListener(wsError);
    browser.webRequest.onAuthRequired.removeListener(wsAuth);
    browser.proxy.onRequest.removeListener(wsProxy);
};
wsRegister();
'registered';
