#!/usr/bin/env python3
"""Check a primary cookie matrix against explicit cookie and Safari privacy expectations."""
import argparse
import json
from urllib.parse import urlsplit
from pathlib import Path


def cookies(operation):
    return sorted(name for name in operation.get('value', {}).get('cookies', {})
                  if name.startswith(('extck_h_', 'extck_s_')))


def expected(base, same_site=True):
    prefixes = ['h', 's'] if base.startswith('https:') else ['h']
    kinds = ['unspecified', 'none', 'lax', 'strict'] if same_site else ['unspecified', 'none']
    return sorted('extck_' + prefix + '_' + kind + suffix
                  for prefix in prefixes for kind in kinds for suffix in ['', '_http'])


def check_matrix(rows):
    checks = []

    def check(name, ok, detail):
        checks.append(dict(name=name, ok=bool(ok), detail=detail))

    check('matrix contains exercises', any(row['context'] != 'seed' for row in rows), [])
    for row in rows:
        if row['context'] == 'seed':
            continue
        ident = [row['fixture'], row['context'], row['policy'], row['base']]
        result = row['result']
        host = urlsplit(row['base']).hostname
        if 'results' not in result:
            check('exercise completes', False, ident)
            continue
        required = {'fetch-include', 'fetch-omit', 'fetch-same-origin', 'fetch-post',
                    'xhr-true', 'xhr-false', 'websocket'}
        check('exercise contains every transport', required <= {q['kind'] for q in result['results']}, ident)
        allowed = row['fixture'] == 'all' or (
            row['fixture'] in ['some', 'http-only'] and host == 'localhost'
            and (row['fixture'] == 'some' or row['base'].startswith('http:')))
        for operation in result['results']:
            kind = operation['kind']
            detail = [*ident, kind]
            if kind == 'metadata':
                continue
            check('network operation completes', 'error' not in operation, detail)
            if 'error' in operation:
                continue
            sent = cookies(operation)
            if kind == 'fetch-omit':
                check('omit sends no fixture cookies', not sent, detail)
            if row['context'] in ['global', 'tab']:
                if allowed and kind in required - {'fetch-omit'}:
                    check('permitted direct request sends all SameSite variants',
                          sent == expected(row['base']), detail + [sent])
                if not allowed and kind in ['fetch-include', 'fetch-post', 'xhr-true', 'websocket']:
                    check('denied request has no Lax/Strict exception',
                          not any('_lax' in name or '_strict' in name for name in sent), detail + [sent])
                if row['fixture'] == 'some' and kind in ['denied-allowed', 'allowed-denied-allowed']:
                    check('denied redirect hop taints returning request',
                          not any('_lax' in name or '_strict' in name for name in sent), detail + [sent])
            if row['fixture'] == 'web':
                # A same-origin request in a cross-site iframe still has a cross-site cookie context.
                same_site = row['context'] == 'web' and host == 'localhost'
                same_origin = row['context'] == 'web-cross-site-iframe' or host == 'localhost'
                want = expected(row['base'], same_site) if same_site or row['policy'] == 0 else []
                if kind == 'fetch-omit' or (not same_origin and kind in ['fetch-same-origin', 'xhr-false']):
                    want = []
                check('ordinary web follows explicit SameSite and privacy policy', sent == want,
                      detail + [dict(sent=sent, expected=want)])
            if row['context'] == 'extension-iframe' and host == '127.0.0.1' and row['policy'] != 0:
                check('extension iframe retains web top third-party block', not sent, detail + [sent])
    return dict(checks=len(checks), failures=[check for check in checks if not check['ok']])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path, help='JSON produced by check-extension-cookies.py run')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    rows = json.loads(args.results.read_text())
    report = check_matrix(rows)
    required = set()
    for policy in [0, 2, 1]:
        for fixture in ['all', 'some', 'none', 'http-only']:
            for scheme, port in [('http', 8877), ('https', 8878)]:
                for host in ['localhost', '127.0.0.1']:
                    for context in ['global', 'tab']:
                        required.add((fixture, context, policy, scheme + '://' + host + ':' + str(port)))
            for host in ['localhost', '127.0.0.1']:
                required.add((fixture, 'extension-iframe', policy, 'http://' + host + ':8877'))
        for host in ['localhost', '127.0.0.1']:
            required.add(('web', 'web', policy, 'http://' + host + ':8877'))
        required.add(('web', 'web-cross-site-iframe', policy, 'http://127.0.0.1:8877'))
    actual = {(row['fixture'], row['context'], row['policy'], row['base']) for row in rows if row['context'] != 'seed'}
    missing = sorted(required - actual)
    report['checks'] += 1
    if missing:
        report['failures'].append(dict(name='full primary matrix coverage', ok=False, detail=missing))
    output = args.output or args.results.with_name('matrix-checks.json')
    output.write_text(json.dumps(report, indent=2))
    print('Matrix checks:', report['checks'], 'FAILURES:', len(report['failures']))
    for failure in report['failures'][:40]:
        print(failure)
    return bool(report['failures'])


if __name__ == '__main__':
    raise SystemExit(main())
