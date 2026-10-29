#!/usr/bin/env python3
"""Bar, worker, embedded-web and fresh-host acceptance cases for the cookie fixture."""
import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('cookies', Path(__file__).with_name('check-extension-cookies.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
phase = sys.argv[1]
output = probe.WORK / (phase + '-extra.json')
rows = json.loads(output.read_text()) if output.exists() else []
done = {(r['fixture'],r['context'],r['policy']) for r in rows}


def record(fixture, context, policy, result):
    row = dict(fixture=fixture, context=context, policy=policy, result=result)
    rows.append(row)
    (probe.WORK / (phase + '-extra.json')).write_text(json.dumps(rows, indent=2))
    print(fixture, context, policy, flush=True)


saved_policy = probe.current_policy()
try:
    probe.policy(0)
    for host in ['ext-cookie.test', 'a.ext-cookie.test']:
        number = probe.window('http://' + host + ':8877/seed')
        probe.close(number)
    for policy in [0, 2, 1]:
        probe.policy(policy)
        for fixture in ['all', 'some', 'none', 'http-only']:
            number = probe.window(probe.roots()[fixture])
            for context in ['global-worker', 'global-shared', 'tab-worker', 'tab-shared'] + (['bar', 'popover'] if fixture == 'all' else []):
                for scheme, port in [('http', 8877), ('https', 8878)]:
                    for host in ['localhost', '127.0.0.1']:
                        case_context = context + '-' + scheme + '-' + host
                        if (fixture,case_context,policy) in done: continue
                        options = dict(base=scheme + '://' + host + ':' + str(port), id=phase + '-' + str(policy) + '-' + fixture + '-' + case_context)
                        if context.startswith('tab-'):
                            expression = 'cookieWorker(' + json.dumps(options) + ',' + json.dumps(context.endswith('shared')) + ')'
                        else:
                            expression = 'browser.runtime.sendMessage(' + json.dumps(dict(cookieTest=context, options=options)) + ')'
                        record(fixture, case_context, policy, probe.exercise(number, expression))
            if fixture == 'some':
                for host in ['ext-cookie.test', 'a.ext-cookie.test']:
                    options = dict(base='http://' + host + ':8877', id=phase + '-wildcard-' + str(policy) + '-' + host)
                    record(fixture, 'wildcard-' + host, policy, probe.exercise(number, 'cookieExercise(' + json.dumps(options) + ')'))
            if fixture == 'all':
                for context in ['global', 'tab']:
                    if (fixture,'fresh-' + context + '-read',policy) in done: continue
                    base = 'http://r20261028-' + phase + '-' + str(policy) + '-' + context + '.ext-cookie.test:8877'
                    options = dict(base=base, id=phase + '-fresh-' + str(policy) + '-' + context, seed='extck_fresh')
                    expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest=context, options=options)) + ')' if context == 'global' else 'cookieExercise(' + json.dumps(options) + ')')
                    record(fixture, 'fresh-' + context + '-seed', policy, probe.exercise(number, expression))
                    options.pop('seed')
                    expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest=context, options=options)) + ')' if context == 'global' else 'cookieExercise(' + json.dumps(options) + ')')
                    record(fixture, 'fresh-' + context + '-read', policy, probe.exercise(number, expression))
                record(fixture, 'service-worker', policy, probe.exercise(number, "navigator.serviceWorker.register('worker.js').then(()=>({registered:true}),e=>({error:String(e)}))"))
                probe.js(number, 'window.cookieResults=[]; addEventListener("message",e=>{if(e.data&&e.data.cookieResult)cookieResults.push(e.data.cookieResult)}); window.cookieFrame=document.createElement("iframe"); window.cookieLoaded=false; cookieFrame.onload=()=>cookieLoaded=true; cookieFrame.src="http://localhost:8877/cookie-frame.html"; document.body.appendChild(cookieFrame); "created"')
                probe.wait(lambda: probe.js(number, 'cookieLoaded') == 'true', 'embedded web frame')
                for host in ['localhost', '127.0.0.1']:
                    options = dict(base='http://' + host + ':8877', id=phase + '-embedded-web-' + str(policy) + '-' + host, redirects=(host == 'localhost'))
                    probe.js(number, 'cookieResults=[]; cookieFrame.contentWindow.postMessage(' + json.dumps(dict(cookieTest='exercise', options=options)) + ', "*"); "sent"')
                    result = json.loads(probe.wait(lambda: probe.js(number, 'cookieResults.length ? JSON.stringify(cookieResults[0]) : ""'), 'embedded web result', 60))
                    record(fixture, 'embedded-web-' + host, policy, result)
            probe.close(number)
finally:
    probe.policy(saved_policy)
