#!/usr/bin/env python3
"""Check extension parents navigating an existing cross-site child, in WK1 and WK2."""
import importlib.util
import json
import os
from pathlib import Path
import uuid


def main():
    spec = importlib.util.spec_from_file_location('cookies', Path(__file__).with_name('check-extension-cookies.py'))
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    expected = {'extck_h_' + kind + suffix for kind in ['unspecified', 'none', 'lax', 'strict']
                for suffix in ['', '_http']}
    saved_policy = probe.current_policy()
    rows = []
    run_id = uuid.uuid4().hex
    try:
        for policy in [0, 2, 1]:
            probe.policy(policy)
            for fixture in ['all', 'some', 'web', 'web-extension-child']:
                number = probe.window('http://localhost:8877/cookie-frame.html' if fixture.startswith('web') else probe.roots()[fixture])
                try:
                    for context in ['web'] if fixture.startswith('web') else ['global', 'tab']:
                        options = dict(id=run_id + '-' + fixture + '-' + context + '-' + str(policy), initialHost='a.ext-cookie.test' if fixture == 'some' else '127.0.0.1')
                        if fixture == 'web-extension-child':
                            options.update(initialURL=probe.roots()['all'], targetHost='127.0.0.1')
                        expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global-navigation', options=options)) + ')'
                                      if context == 'global' else 'cookieParentNavigation(' + json.dumps(options) + ')')
                        events = []
                        if not fixture.startswith('web'):
                            probe.js(number, 'window.childNavigationEvents=[];window.childNavigationListener=d=>{'
                                     + 'if(d.url.includes(' + json.dumps(options['id']) + '))childNavigationEvents.push('
                                     + '{url:d.url,initiator:d.initiator,documentUrl:d.documentUrl,headers:d.requestHeaders'
                                     + '.filter(h=>h.name.toLowerCase()==="cookie").map(h=>({name:h.name,value:h.value.split(/; */).filter(c=>c.startsWith("extck_")).join("; ")}))})};'
                                     + 'browser.webRequest.onBeforeSendHeaders.addListener(childNavigationListener,'
                                     + '{urls:["http://localhost/*","http://127.0.0.1/*"]},["requestHeaders","extraHeaders"]);"registered"')
                        try:
                            result = probe.exercise(number, expression)
                            if not fixture.startswith('web'):
                                events = json.loads(probe.js(number, 'JSON.stringify(childNavigationEvents)'))
                        finally:
                            if not fixture.startswith('web'):
                                probe.js(number, 'browser.webRequest.onBeforeSendHeaders.removeListener(childNavigationListener);"removed"')
                        sent = {name for name in result.get('result', {}).get('request', {}).get('cookies', {}) if name.startswith('extck_h_')}
                        wanted = expected
                        if fixture == 'web-extension-child':
                            wanted = {name for name in expected if '_lax' not in name and '_strict' not in name} if policy == 0 else set()
                        rows.append(dict(fixture=fixture, context=context, policy=policy, result=result, events=events,
                                         expected=sorted(wanted), ok=result.get('initialLoaded') is True and wanted == sent))
                        (probe.WORK / 'parent-navigation.json').write_text(json.dumps(rows, indent=2))
                finally:
                    probe.close(number)
    finally:
        probe.policy(saved_policy)
    failures = [row for row in rows if not row['ok']]
    print('Existing-child navigation:', len(rows), 'FAILURES:', len(failures))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
