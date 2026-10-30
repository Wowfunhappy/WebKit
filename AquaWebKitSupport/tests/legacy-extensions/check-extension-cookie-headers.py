#!/usr/bin/env python3
"""Compare generated extraHeaders Cookie fields with wire headers and header verdicts."""
import argparse
from http.cookies import SimpleCookie
import importlib.util
import json
import os
from pathlib import Path
from urllib.parse import urlsplit


def compare_row(row):
    failures = []
    checks = 0
    expected = {'extck_h_' + kind + suffix for kind in ['unspecified', 'none', 'lax', 'strict']
                for suffix in ['', '_http']}

    def check(ok, reason, **detail):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(dict(reason=reason, **detail))

    operations = row['result'].get('results', [])
    check({'fetch-include', 'fetch-omit', 'fetch-same-origin', 'fetch-post', 'xhr-true',
           'xhr-false', 'websocket'} <= {operation['kind'] for operation in operations},
          'all transports complete')
    for operation in operations:
        kind = operation['kind']
        if kind == 'metadata':
            continue
        check('error' not in operation, 'operation completes', operation=operation)
        if 'error' in operation:
            continue
        wire = operation['value']
        events = [event for event in row['events']
                  if urlsplit(event['url']).netloc == wire['host']
                  and urlsplit(event['url']).path + ('?' + urlsplit(event['url']).query
                                                   if urlsplit(event['url']).query else '') == wire['path']]
        check(len(events) == 1, 'one generated-header event matches the wire request', kind=kind, events=events)
        if len(events) != 1:
            continue
        generated = SimpleCookie()
        for header in events[0]['headers']:
            if header['name'].lower() == 'cookie':
                generated.load(header['value'])
        sent = wire['cookies']
        generated = {name: cookie.value for name, cookie in generated.items() if name.startswith('extck_')}
        check(not generated if kind == 'fetch-omit' else expected <= generated.keys(),
              'generated header respects credentials and includes Lax/Strict', kind=kind, generated=generated)
        wanted = {} if row['mode'] == 'remove' else generated
        check(sent == wanted, 'wire header matches generated header or removal verdict',
              kind=kind, generated=generated, sent=sent, expected=wanted)
        if row['mode'] == 'origin':
            check(wire['origin'] == 'http://127.0.0.1:8877', 'Origin verdict reaches wire', kind=kind, wire=wire)
    return dict(checks=checks, failures=failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', nargs='?', default='verified')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('cookies', Path(__file__).with_name('check-extension-cookies.py'))
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    rows = []
    saved_policy = probe.current_policy()
    number = None
    try:
        probe.policy(0)
        number = probe.window(probe.roots()['all'])
        for mode in ['observe', 'remove', 'origin']:
            probe.js(number, '''window.cookieHeaderEvents=[];
window.cookieHeaderListener = details => {
    cookieHeaderEvents.push({url:details.url, headers:details.requestHeaders.filter(h=>['cookie','origin'].includes(h.name.toLowerCase())).map(h=>({name:h.name,value:h.name.toLowerCase()==='cookie'?h.value.split(/; */).filter(c=>c.startsWith('extck_')).join('; '):h.value}))});
    if (''' + json.dumps(mode) + ''' === 'remove')
        return {requestHeaders:details.requestHeaders.filter(h=>h.name.toLowerCase()!=='cookie')};
    if (''' + json.dumps(mode) + ''' === 'origin')
        return {requestHeaders:details.requestHeaders.filter(h=>h.name.toLowerCase()!=='origin').concat([{name:'Origin',value:'http://127.0.0.1:8877'}])};
};
browser.webRequest.onBeforeSendHeaders.addListener(cookieHeaderListener,
{urls:['http://localhost/*','ws://localhost/*']},
''' + json.dumps(['requestHeaders', 'extraHeaders'] + ([] if mode == 'observe' else ['blocking'])) + '''); 'registered' ''')
            try:
                for context in ['global', 'tab']:
                    probe.js(number, 'window.cookieHeaderEvents=[]; "reset"')
                    options = dict(base='http://localhost:8877', id=args.phase + '-headers-' + mode + '-' + context)
                    expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global', options=options)) + ')'
                                  if context == 'global' else 'cookieExercise(' + json.dumps(options) + ')')
                    result = probe.exercise(number, expression)
                    events = json.loads(probe.js(number, 'JSON.stringify(cookieHeaderEvents)'))
                    row = dict(mode=mode, context=context, result=result, events=events)
                    row['comparison'] = compare_row(row)
                    rows.append(row)
                    (probe.WORK / (args.phase + '-headers.json')).write_text(json.dumps(rows, indent=2))
            finally:
                probe.js(number, "browser.webRequest.onBeforeSendHeaders.removeListener(cookieHeaderListener); 'removed'")
    finally:
        try:
            if number is not None:
                probe.close(number)
        finally:
            probe.policy(saved_policy)
    failures = sum(len(row['comparison']['failures']) for row in rows)
    print('Header comparisons:', sum(row['comparison']['checks'] for row in rows), 'FAILURES:', failures)
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
