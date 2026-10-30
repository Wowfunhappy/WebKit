#!/usr/bin/env node
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const source = fs.readFileSync(path.resolve(__dirname, '../../source/WebKit/Shared/LegacyExtensions/LegacyExtensionAPI.js'), 'utf8');
const dispatch = new Function('native', 'filterMatches', 'hasExtraInfo', 'isBlocking',
    source.slice(source.indexOf('const optionalDetails ='), source.indexOf("// Firefox's proxy.onError"))
    + '\nreturn dispatchWebRequestEvent;')({isValid:()=>true}, ()=>true,
        (entry, name)=>entry.extra.includes(name), entry=>entry.extra.includes('blocking'));
const field = (name, value) => ({name, value});
const listener = (extra, callback) => ({extra, callback});
const run = (details, listeners) => dispatch({_listeners:listeners}, details);
const request = ['blocking','requestHeaders'];
const response = ['blocking','responseHeaders'];

(async () => {
    const details = {url:'ws://localhost/', type:'websocket',
        requestHeaders:[field('Connection','Upgrade'),field('Cookie','a=1')],
        requestBody:{raw:[{bytes:'AQID'}]}};
    const original = JSON.stringify(details);
    let observed;
    await run(details, [
        listener(request.concat(['extraHeaders','requestBody']), d=>{
            d.requestHeaders[0].value='mutated';
            new Uint8Array(d.requestBody.raw[0].bytes)[0]=9;
            return {requestHeaders:[field('Authorization','injected')]};
        }),
        listener(['requestHeaders','requestBody'], d=>{observed=d;})
    ]);
    assert.deepStrictEqual(observed.requestHeaders,[field('Connection','Upgrade')]);
    assert.deepStrictEqual(Array.from(new Uint8Array(observed.requestBody.raw[0].bytes)),[1,2,3]);
    assert.strictEqual(JSON.stringify(details),original);

    const merged = await run({requestHeaders:[field('Cookie','a=1'),field('X-First','original')]}, [
        listener(request.concat('extraHeaders'), ()=>({requestHeaders:[field('X-First','edited')]})),
        listener(request, d=>({requestHeaders:d.requestHeaders.concat(field('X-Second','added'))}))
    ]);
    assert.deepStrictEqual(merged.requestHeaders,[field('X-First','edited'),field('X-Second','added')]);

    const replaced = await run({requestHeaders:[field('Cookie','a=1')]}, [
        listener(request.concat('extraHeaders'), ()=>({requestHeaders:[field('Cookie','b=2')]})),
        listener(request, ()=>({requestHeaders:[field('Cookie','forbidden'),field('X-Second','added')]}))
    ]);
    assert.deepStrictEqual(replaced.requestHeaders,[field('Cookie','b=2'),field('X-Second','added')]);

    const cookies = await run({responseHeaders:[field('Set-Cookie','a=1'),field('Set-Cookie','b=2'),field('X-First','original')]}, [
        listener(response.concat('extraHeaders'), ()=>({responseHeaders:[field('Set-Cookie','b=2'),field('X-First','edited')]})),
        listener(response, d=>({responseHeaders:d.responseHeaders.concat(field('X-Second','added'))}))
    ]);
    assert.deepStrictEqual(cookies.responseHeaders,[field('Set-Cookie','b=2'),field('X-First','edited'),field('X-Second','added')]);

    const repeated = await run({responseHeaders:[field('X-List','a')]}, [
        listener(response, d=>({responseHeaders:d.responseHeaders.concat(field('X-List','b'))})),
        listener(response, d=>({responseHeaders:d.responseHeaders.concat(field('x-list','c'))}))
    ]);
    assert.deepStrictEqual(repeated.responseHeaders,[field('X-List','a'),field('X-List','b'),field('x-list','c')]);
    console.log('PASS: listener snapshots, binary bodies, request deltas, extraHeaders isolation and response-field deltas');
})().catch(error=>{console.error(error);process.exitCode=1;});
