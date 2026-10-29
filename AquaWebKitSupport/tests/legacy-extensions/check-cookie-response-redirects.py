#!/usr/bin/env python3
"""Check onHeadersReceived hop taint for WK1/WK2 fetch and ping requests."""
import importlib.util
import json
import os
from pathlib import Path
from urllib.parse import urlencode
import uuid


def main():
    spec = importlib.util.spec_from_file_location('cookies', Path(__file__).with_name('check-extension-cookies.py'))
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    saved_policy = probe.current_policy()
    windows = []
    rows = []
    auditing = None
    listener_window = None
    try:
        probe.policy(0)
        listener_window = probe.window(probe.roots()['all'])
        windows.append(listener_window)
        auditing = probe.exercise(listener_window, 'browser.privacy.websites.hyperlinkAuditingEnabled.get({})')
        enabled = probe.exercise(listener_window, 'browser.privacy.websites.hyperlinkAuditingEnabled.set({value:true}).then(()=>browser.privacy.websites.hyperlinkAuditingEnabled.get({}))')
        assert enabled.get('value') is True, enabled
        (probe.WORK / 'response-redirects-settings.json').write_text(json.dumps(dict(before=auditing, during=enabled), indent=2))
        requester = probe.window(probe.roots()['some'])
        windows.append(requester)
        for context in ['global', 'tab']:
            for kind in ['fetch', 'ping']:
                for initial_host in ['localhost', '127.0.0.1']:
                    case_id = uuid.uuid4().hex
                    start_path = '/echo?' + urlencode(dict(id=case_id + '-initial'))
                    end_path = '/echo?' + urlencode(dict(id=case_id + '-final'))
                    start = 'http://' + initial_host + ':8877' + start_path
                    end = 'http://localhost:8877' + end_path
                    probe.js(listener_window, 'window.cookieRedirectListener=d=>d.url===' + json.dumps(start)
                             + '?{redirectUrl:' + json.dumps(end) + '}:undefined;'
                             + 'browser.webRequest.onHeadersReceived.addListener(cookieRedirectListener,'
                             + '{urls:["http://localhost/*","http://127.0.0.1/*"]},["blocking","responseHeaders"]);"registered"')
                    try:
                        options = dict(kind=kind, url=start, pingTransport='hyperlink' if context == 'global' else 'beacon')
                        expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global-response-redirect', options=options)) + ')'
                                      if context == 'global' else 'cookieResponseRedirect(' + json.dumps(options) + ')')
                        result = probe.exercise(requester, expression)

                        def requests():
                            values = []
                            for line in (probe.WORK / 'server.jsonl').read_text().splitlines():
                                try:
                                    request = json.loads(line).get('request', {})
                                except ValueError:
                                    continue
                                if request.get('path') in [start_path, end_path]:
                                    values.append(request)
                            return values

                        def completed():
                            values = requests()
                            return values if any(value['path'] == end_path for value in values) else None

                        error = None
                        try:
                            wire = probe.wait(completed, 'response-verdict redirect reaches wire')
                        except RuntimeError as failure:
                            error = str(failure)
                            wire = requests()
                        final = next((request for request in reversed(wire) if request['path'] == end_path), {})
                        sent = {name for name in final.get('cookies', {}) if name.startswith('extck_h_')}
                        variants = ['unspecified', 'none', 'lax', 'strict'] if initial_host == 'localhost' else ['unspecified', 'none']
                        expected = {'extck_h_' + variant + suffix for variant in variants for suffix in ['', '_http']}
                        ok = bool(final) and sent == expected and any(request['path'] == start_path for request in wire)
                        if kind == 'ping':
                            ok = ok and result.get('queued') is True
                        else:
                            ok = ok and result.get('path') == end_path
                        rows.append(dict(context=context, kind=kind, initialHost=initial_host, result=result,
                                         wire=wire, expected=sorted(expected), error=error, ok=ok))
                        (probe.WORK / 'response-redirects.json').write_text(json.dumps(rows, indent=2))
                    finally:
                        probe.js(listener_window, 'browser.webRequest.onHeadersReceived.removeListener(cookieRedirectListener);"removed"')
    finally:
        try:
            if auditing is not None:
                operation = ('set(' + json.dumps(dict(value=auditing['value'])) + ')'
                             if auditing.get('levelOfControl') == 'controlled_by_this_extension' else 'clear({})')
                restored = probe.exercise(listener_window, 'browser.privacy.websites.hyperlinkAuditingEnabled.' + operation + '.then(()=>browser.privacy.websites.hyperlinkAuditingEnabled.get({}))')
                settings = json.loads((probe.WORK / 'response-redirects-settings.json').read_text())
                settings['after'] = restored
                (probe.WORK / 'response-redirects-settings.json').write_text(json.dumps(settings, indent=2))
                assert restored == auditing, (auditing, restored)
        finally:
            try:
                for number in reversed(windows):
                    probe.close(number)
            finally:
                probe.policy(saved_policy)
    failures = [row for row in rows if not row['ok']]
    print('Response redirect chains:', len(rows), 'FAILURES:', len(failures))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
