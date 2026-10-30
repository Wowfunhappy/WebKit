#!/usr/bin/env python3
"""Check cookie headers and the complete WS/WSS webRequest handshake lifecycle."""
import argparse
from collections import Counter
from http.cookies import SimpleCookie
import importlib.util
import json
import os
from pathlib import Path
import time
from urllib.parse import parse_qs, urlencode, urlsplit
import uuid

HERE = Path(__file__).resolve().parent
PROTECTED = {'host', 'sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol',
             'sec-websocket-extensions', 'authorization', 'proxy-authorization', 'connection',
             'upgrade', 'content-length', 'transfer-encoding', 'pragma', 'cache-control', 'proxy-connection'}
HIDDEN = PROTECTED - {'upgrade', 'connection', 'sec-websocket-version'}
NETWORK_MODES = {'network-redirect', 'proxy-route', 'hop-cancel'}


def fixture_cookies(scheme, same_site):
    return {'extck_' + prefix + '_' + kind + suffix: '1'
            for prefix in (['h', 's'] if scheme == 'wss' else ['h'])
            for kind in (['unspecified', 'none', 'lax', 'strict'] if same_site else ['unspecified', 'none'])
            for suffix in ['', '_http']}


def header_cookies(headers):
    jar = SimpleCookie()
    for header in headers:
        if header['name'].lower() == 'cookie':
            jar.load(header['value'])
    return {name: item.value for name, item in jar.items()}


def cases_for(policy, context, baseline=False):
    cases = [('observe', [host], 302) for host in ['localhost', '127.0.0.1']]
    chains = [['localhost', 'ext-cookie.test'], ['localhost', '127.0.0.1'],
              ['127.0.0.1', 'localhost'], ['localhost', '127.0.0.1', 'ext-cookie.test']]
    cases += [(mode, hosts, 302) for mode in ['network-redirect', 'verdict-redirect'] for hosts in chains]
    if baseline:
        return cases
    cases += [(mode, ['localhost'], 302) for mode in ['remove', 'replace', 'cancel', 'protected',
              'response-cancel', 'response-repair', 'response-reject', 'response-redirect',
              'auth', 'auth-cancel', 'pass-through', 'pending-headers-close', 'pending-headers-navigate',
              'pending-received-close', 'pending-received-navigate']]
    cases.append(('proxy-route', ['localhost', '127.0.0.1', 'ext-cookie.test'], 302))
    if context == 'tab':
        cases.append(('hop-cancel', ['localhost', 'ext-cookie.test'], 302))
    if policy == 0:
        cases += [('network-redirect', ['localhost', 'ext-cookie.test'], status) for status in [301, 303, 307, 308]]
    return cases


def check_case(row):
    failures = []
    checks = 0
    def check(ok, reason, detail=None):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(dict(case=row['id'], reason=reason, detail=detail))
    mode, context, scheme, policy = (row[k] for k in ['mode', 'context', 'scheme', 'policy'])
    wire, events, hosts = row['wire'], row['events'], row['hosts']
    pending = mode.startswith('pending-')
    headers = mode != 'pass-through'
    rejected = mode in ['cancel', 'response-cancel', 'response-reject', 'hop-cancel', 'auth-cancel'] or pending
    rejected |= context == 'global' and (mode in NETWORK_MODES or mode == 'auth')
    expected_hops = len(hosts) if context == 'tab' and mode in NETWORK_MODES else 1
    if mode == 'auth' and context == 'tab':
        expected_hops = 2
    if mode == 'hop-cancel':
        expected_hops = 1
    if mode == 'cancel' or mode.startswith('pending-headers-'):
        expected_hops = 0
    check(len(wire) == expected_hops, 'wire hop count', [len(wire), expected_hops])
    if not pending:
        result = row['result']
        check(not result.get('timeout') and result.get('opened') is (not rejected)
              and result.get('error') is rejected and result.get('code') == (1006 if rejected else 1000), 'client outcome', result)
    terminal = [event for event in events if event['stage'] in ['complete', 'error']]
    check(len(terminal) == 1 and terminal[0]['stage'] == ('error' if rejected else 'complete'), 'exactly one terminal event', terminal)
    if terminal and rejected:
        blocked = mode in ['cancel', 'response-cancel', 'hop-cancel'] or (mode == 'auth-cancel' and context == 'tab')
        expected_error = 'net::ERR_BLOCKED_BY_CLIENT' if blocked else ('net::ERR_ABORTED' if pending else None)
        check(terminal[0].get('error') == expected_error if expected_error else terminal[0].get('error', '').startswith('net::ERR_'), 'terminal error', terminal[0])
    check(len({event['requestId'] for event in events}) == 1, 'stable request ID across exchanges')
    check(all(event['type'] == 'websocket' for event in events), 'WebSocket event type')
    stages = [event['stage'] for event in events if event['extra']]
    prefix = ['proxy', 'before']
    sent = ['headers', 'sent'] if headers else []
    if mode == 'cancel' or mode.startswith('pending-headers-'):
        expected_stages = prefix + ['headers', 'error']
    elif pending or mode in ['response-cancel', 'response-reject']:
        expected_stages = prefix + sent + ['received', 'error']
    elif mode in ['auth', 'auth-cancel']:
        expected_stages = prefix + sent + ['received']
        if context == 'tab':
            expected_stages += ['auth'] + (sent + ['received', 'response', 'complete'] if mode == 'auth' else ['error'])
        else:
            expected_stages += ['error']
    elif mode in NETWORK_MODES:
        expected_stages = prefix + sent + ['received']
        if context == 'global':
            expected_stages += ['error']
        elif mode == 'hop-cancel':
            expected_stages += ['redirect'] + prefix + ['error']
        else:
            for _ in hosts[1:]:
                expected_stages += ['redirect'] + prefix + sent + ['received']
            expected_stages += ['response', 'complete']
    else:
        expected_stages = prefix + sent + ['received', 'response', 'complete']
    check(stages == expected_stages, 'event order', dict(expected=expected_stages, actual=stages))
    history_allowed = True
    seen = Counter()
    for hop, request in enumerate(wire):
        host_index = 0 if mode in ['auth', 'auth-cancel'] else hop
        history_allowed &= hosts[host_index] != '127.0.0.1'
        blocked = context == 'tab' and policy != 0 and hosts[host_index] == '127.0.0.1'
        expected = {} if blocked else fixture_cookies(scheme, history_allowed)
        if mode == 'remove':
            expected = {}
        if mode == 'replace':
            expected = {'extck_ws_override': '1'}
        check(request['cookies'] == expected, 'cookie permission history', dict(hop=hop, expected=expected, actual=request['cookies']))
        check(request['host'] == hosts[host_index] + ':' + str(8878 if scheme == 'wss' else 8877), 'wire host', request['host'])
        key = (request['host'], request['path'])
        index = seen[key]
        seen[key] += 1
        matching = [event for event in events if urlsplit(event['url']).netloc == request['host']
                    and urlsplit(event['url']).path + '?' + urlsplit(event['url']).query == request['path']]
        for stage in ['headers', 'sent']:
            selected = [event for event in matching if event['stage'] == stage and event['extra']]
            if not headers:
                check(not selected, 'unsubscribed header event')
                continue
            check(len(selected) > index, 'header event for wire exchange', [hop, stage])
            if len(selected) <= index:
                continue
            actual = header_cookies(selected[index]['headers'])
            want = header_cookies([{'name':'Cookie', 'value':request['cookieHeader']}])
            if stage == 'headers' and mode in ['remove', 'replace']:
                actual = {k:v for k,v in actual.items() if k.startswith('extck_')}
                want = fixture_cookies(scheme, True)
            else:
                shown = next((h['value'] for h in selected[index]['headers'] if h['name'].lower() == 'cookie'), '')
                check(shown == request['cookieHeader'], 'Cookie text matches wire', [hop, stage])
            check(actual == want, 'Cookie values match wire/verdict', [hop, stage, actual, want])
            plain = [event for event in matching if event['stage'] == stage and not event['extra']]
            check(len(plain) > index and not header_cookies(plain[index]['headers']), 'Cookie hidden without extraHeaders', [hop, stage])
        actual_headers = {name.lower():value for name,value in request['handshakeHeaders'].items()}
        check('fixture-injection' not in actual_headers.values(), 'transport fields resist injection', actual_headers)
        check('content-length' not in actual_headers and 'proxy-authorization' not in actual_headers, 'no injected length or origin proxy credential')
        check(actual_headers.get('sec-websocket-version') == '13', 'transport WebSocket version')
        check(actual_headers.get('sec-websocket-protocol') == 'cookie-protocol', 'transport subprotocol')
        if mode == 'auth' and context == 'tab' and hop == 1:
            check(actual_headers.get('authorization') == 'Basic Y29va2llLXdzOmNvb2tpZS1wYXNzd29yZA==', 'auth credential reaches protected transport field')
        if mode == 'replace':
            check(request['testHeader'] == 'handshake', 'editable header reaches wire')
        if mode in ['remove', 'replace']:
            check(actual_headers.get('x-cookie-merge') == 'listener', 'later non-extraHeaders edit preserves the Cookie verdict')
    for event in events:
        if event['stage'] in ['headers', 'sent', 'proxy']:
            check(not HIDDEN.intersection(h['name'].lower() for h in event['headers']), 'hidden headers absent from listeners', event)
        if event['stage'] in ['headers', 'sent'] and event['extra']:
            shown = {h['name'].lower(): h['value'] for h in event['headers']}
            check(shown.get('connection') == 'Upgrade', 'Connection is visible and protected', event)
        if event['stage'] in ['received', 'response', 'complete'] and event.get('statusCode') == 101:
            check(event.get('statusLine') == 'HTTP/1.1 101 Switching Protocols', 'complete upgrade status line', event)
    if mode == 'proxy-route':
        proxies = [item for item in row['proxy'] if item['authorized']]
        want = [row['proxyPorts'][0]] + ([row['proxyPorts'][1]] * (len(hosts) - 1) if context == 'tab' else [])
        check([item['port'] for item in proxies] == want, 'fresh proxy route on each followed hop', proxies)
    if pending:
        check(row.get('terminalBeforeRelease') is True, 'close terminates before late verdict')
        check(len(terminal) == row.get('terminalCountBeforeRelease') == 1, 'late verdict adds no terminal event')
        if 'received' in mode:
            check(row['ends'] and all(item.get('clientBytes') == 0 for item in row['ends']), 'no frame/write after held response', row['ends'])
    if mode == 'pass-through':
        check(wire and row['control']['headerOrder'] == wire[0]['headerOrder'], 'unobserved header order stays unchanged')
    return dict(checks=checks, failures=failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', default='verified')
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--proxy-ports', nargs=2, type=int, default=[8879, 8880])
    args = parser.parse_args()
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    spec = importlib.util.spec_from_file_location('probe', HERE / 'check-extension-cookies.py')
    p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
    trace_spec = importlib.util.spec_from_file_location('console_trace', HERE / 'websocket-console.py')
    trace_module = importlib.util.module_from_spec(trace_spec); trace_spec.loader.exec_module(trace_module)
    rows, windows = [], []
    observer = None
    trace = None
    saved_policy = p.current_policy()
    output = p.WORK / (args.phase + '-websockets.json')
    def log():
        return [json.loads(line) for line in (p.WORK / 'server.jsonl').read_text().splitlines()]
    def events():
        return json.loads(p.js(observer, 'JSON.stringify(wsEvents)'))
    def terminal_events():
        return [event for event in events() if event['stage'] in ['error', 'complete']]
    def expression(context, options):
        return ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global-websocket', options=options)) + ')'
                if context == 'global' else 'cookieWebSocketProbe(' + json.dumps(options) + ')')
    def save():
        output.write_text(json.dumps(dict(rows=rows, checks=sum(r['comparison']['checks'] for r in rows),
                                        failures=[f for r in rows for f in r['comparison']['failures']]), indent=2))
    try:
        p.policy(0)
        for host in ['localhost', '127.0.0.1', 'ext-cookie.test']:
            for scheme, port in [('http',8877), ('https',8878)]:
                number = p.window(scheme + '://' + host + ':' + str(port) + '/seed'); p.close(number)
        observer = p.window(p.roots()['all']); windows.append(observer)
        requester = p.window(p.roots()['some']); windows.append(requester)
        p.js(observer, (HERE / 'pages/cookie-websocket-observer.js').read_text())
        if not args.baseline:
            trace = trace_module.ConsoleTrace(p.WORK, p.wait)
        for policy in [0,2,1]:
            p.policy(policy)
            for context in ['global','tab']:
                for scheme, port in [('ws',8877), ('wss',8878)]:
                    for mode, hosts, status in cases_for(policy, context, args.baseline):
                        case_id = uuid.uuid4().hex
                        urls = []
                        for hop, host in reversed(list(enumerate(hosts))):
                            query = dict(id=case_id, hop=hop)
                            path = '/ws-auth' if mode in ['auth','auth-cancel'] else '/ws'
                            if mode == 'response-repair': query['badUpgrade'] = 1
                            if mode.startswith('pending-'): query['hold'] = 1
                            if mode in NETWORK_MODES and urls:
                                path = '/ws-redirect'; query.update(to=urls[0], status=status)
                            urls.insert(0, scheme + '://' + host + ':' + str(port) + path + '?' + urlencode(query))
                        action = dict(url=urls[0], mode=mode, proxyPorts=args.proxy_ports)
                        if mode == 'verdict-redirect': action['redirect'] = urls[1]
                        if mode == 'hop-cancel': action['cancelURL'] = urls[1]
                        if mode == 'response-redirect': action['responseRedirect'] = scheme + '://127.0.0.1:' + str(port) + '/ws?id=' + case_id + '-forbidden'
                        if mode.startswith('pending-'): action['hold'] = mode.split('-')[1]
                        control = None
                        if mode == 'pass-through':
                            p.js(observer, 'wsRemove(); wsAction={}; browser.proxy.onRequest.addListener(wsProxy,wsFilter,["requestHeaders"]); "removed"')
                            result = p.exercise(requester, expression(context, dict(url=urls[0].replace(case_id, case_id+'control'), protocol='cookie-protocol')))
                            control = result['messages'][0]
                            p.js(observer, 'browser.proxy.onRequest.removeListener(wsProxy); wsRegister(); wsRemoveHeaders(); "registered"')
                        start = len(log())
                        p.js(observer, 'wsEvents=[]; wsHeld=null; wsAction=' + json.dumps(action) + '; "ready"')
                        options = dict(url=urls[0], protocol='cookie-protocol')
                        extra = {}
                        if mode.startswith('pending-'):
                            p.js(requester, 'window.__pendingSocketResult=null; Promise.resolve(' + expression(context, options) + ').then(v=>window.__pendingSocketResult=v); "started"')
                            p.wait(lambda:p.js(observer, '!!wsHeld') == 'true', 'blocking listener pending')
                            operation = mode.split('-')[2]
                            if context == 'global':
                                p.exercise(requester, 'browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global-websocket-control', action=operation, id=case_id)) + ')')
                            else:
                                command = 'cookieProbeSocket.close()' if operation == 'close' else 'setTimeout(()=>location.replace("page.html?wsNavigation=' + case_id + '"),0)'
                                p.js(requester, command + '; "queued"')
                            terminal = p.wait(terminal_events, 'terminal event while verdict is held')
                            extra.update(terminalBeforeRelease=True, terminalCountBeforeRelease=len(terminal))
                            p.js(observer, 'wsHeld(); wsHeld=null; "released"')
                            time.sleep(.5)
                            if operation == 'navigate':
                                if context == 'global':
                                    p.wait(lambda:any(item.get('report',{}).get('navigation') == case_id for item in log()), 'global page navigation')
                                else:
                                    p.wait(lambda:p.js(requester, 'document.readyState==="complete" && typeof cookieWebSocketProbe==="function"') == 'true', 'tab navigation')
                            result = dict(operation=operation)
                        else:
                            result = p.exercise(requester, expression(context, options))
                            p.wait(terminal_events, 'terminal handshake event')
                        if 'pending-received' in mode:
                            p.wait(lambda:any(item.get('websocketEnd',{}).get('id') == case_id for item in log()), 'closed held-response transport')
                        captured = log()[start:]
                        wire = [item['request'] for item in captured if 'request' in item and parse_qs(urlsplit(item['request']['path']).query).get('id') == [case_id]]
                        row = dict(id=case_id, policy=policy, context=context, scheme=scheme, mode=mode, hosts=hosts,
                                   status=status, urls=urls, result=result, events=events(), wire=wire, control=control,
                                   proxy=[item['proxy'] for item in captured if 'proxy' in item], proxyPorts=args.proxy_ports,
                                   ends=[item['websocketEnd'] for item in captured if item.get('websocketEnd',{}).get('id') == case_id], **extra)
                        row['comparison'] = check_case(row); rows.append(row); save()
                        print(policy, context, scheme, mode, 'wire', len(wire), 'failures', len(row['comparison']['failures']), flush=True)
                        if mode == 'pass-through': p.js(observer, 'wsRegisterHeaders(); "registered"')
    finally:
        cleanup_errors = []
        actions = ([trace.stop] if trace else [])
        if observer is not None:
            actions.append(lambda:p.js(observer, 'if(typeof wsHeld==="function")wsHeld(); if(typeof wsRemove==="function")wsRemove(); "removed"'))
        actions += [lambda number=number:p.close(number) for number in reversed(windows)]
        actions.append(lambda:p.policy(saved_policy))
        for action in actions:
            try:
                action()
            except Exception as error:
                cleanup_errors.append(str(error))
        if cleanup_errors:
            raise RuntimeError('Cleanup failures: ' + repr(cleanup_errors))
    result = json.loads(output.read_text())
    expected_count = 120 if args.baseline else 334
    result['checks'] += 1
    if len(rows) != expected_count: result['failures'].append(dict(reason='complete matrix coverage', actual=len(rows), expected=expected_count))
    if trace:
        result['console'] = trace.report(); result['checks'] += 4
        if result['console']['genericSendFailure'] or result['console']['probeErrors'] or not result['console']['wk1PositiveControl'] or not result['console']['wk2PositiveControl']:
            result['failures'].append(dict(reason='native console checks', detail=result['console']))
    output.write_text(json.dumps(result,indent=2))
    print('WebSocket checks:',result['checks'],'FAILURES:',len(result['failures']))
    return bool(result['failures'])


if __name__ == '__main__':
    raise SystemExit(main())
