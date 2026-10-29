#!/usr/bin/env python3
"""Check the worker, bar/popover, embedded-web and fresh-host cookie matrix."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit


def names(base, same_site=True, fresh=False):
    prefixes = ['fresh'] if fresh else (['h', 's'] if base.startswith('https:') else ['h'])
    kinds = ['unspecified', 'none', 'lax', 'strict'] if same_site else ['unspecified', 'none']
    return sorted('extck_' + prefix + '_' + kind + suffix for prefix in prefixes
                  for kind in kinds for suffix in ['', '_http'])


def check_matrix(rows):
    checks = []
    unsupported = []

    def check(ok, name, detail):
        checks.append(dict(ok=bool(ok), name=name, detail=detail))

    required = set()
    for policy in [0, 2, 1]:
        for fixture in ['all', 'some', 'none', 'http-only']:
            for context in ['global-worker', 'global-shared', 'tab-worker', 'tab-shared'] + (['bar', 'popover'] if fixture == 'all' else []):
                for scheme in ['http', 'https']:
                    for host in ['localhost', '127.0.0.1']:
                        required.add((fixture, context + '-' + scheme + '-' + host, policy))
        for host in ['ext-cookie.test', 'a.ext-cookie.test']:
            required.add(('some', 'wildcard-' + host, policy))
        for context in ['global', 'tab']:
            for stage in ['seed', 'read']:
                required.add(('all', 'fresh-' + context + '-' + stage, policy))
        for host in ['localhost', '127.0.0.1']:
            required.add(('all', 'embedded-web-' + host, policy))
        required.add(('all', 'service-worker', policy))
    seen = {(row['fixture'], row['context'], row['policy']) for row in rows}
    check(required <= seen, 'full supplementary matrix coverage', sorted(required - seen))
    for row in rows:
        fixture, context, policy = row['fixture'], row['context'], row['policy']
        ident = [fixture, context, policy]
        result = row['result']
        if context == 'service-worker':
            check(bool(result.get('registered') or result.get('error')), 'service-worker capability recorded', ident + [result])
            if result.get('error'):
                unsupported.append(dict(case=ident, error=result['error']))
            continue
        check('results' in result, 'exercise completes', ident + [result] if 'results' not in result else ident)
        if 'results' not in result:
            continue
        base = result['base']
        host = urlsplit(base).hostname
        fresh = context.startswith('fresh-')
        embedded = context.startswith('embedded-web-')
        required_operations = {'fetch-include', 'fetch-omit', 'fetch-same-origin', 'fetch-post', 'xhr-true', 'xhr-false', 'websocket'}
        if fresh and context.endswith('-seed'):
            required_operations.add('seed')
        if embedded and host == 'localhost':
            required_operations.update(['allowed-allowed', 'allowed-denied', 'denied-allowed', 'allowed-denied-allowed'])
        check(required_operations <= {operation['kind'] for operation in result['results']}, 'exercise contains every required operation', ident)
        allowed = fixture == 'all' or (fixture in ['some', 'http-only']
                  and (host == 'localhost' or host == 'ext-cookie.test' or host.endswith('.ext-cookie.test'))
                  and (fixture == 'some' or base.startswith('http:')))
        for operation in result['results']:
            kind = operation['kind']
            detail = ident + [kind]
            if kind == 'metadata':
                continue
            check('error' not in operation, 'network operation completes', detail + [operation] if 'error' in operation else detail)
            if 'error' in operation:
                continue
            sent = sorted(name for name in operation.get('value', {}).get('cookies', {})
                          if name.startswith(('extck_fresh_',) if fresh else ('extck_h_', 'extck_s_')))
            if fresh:
                want = names(base, fresh=True) if context.endswith('-read') and policy != 1 else []
            elif embedded:
                same_site = host == 'localhost' and kind not in ['allowed-denied', 'denied-allowed', 'allowed-denied-allowed']
                want = names(base, same_site)
                if host != 'localhost' and kind in ['fetch-same-origin', 'xhr-false']:
                    want = []
            else:
                # WK1 dedicated workers retain the native jar's unrestricted existing-cookie reads.
                native_worker = context.startswith('global-worker-')
                want = names(base, allowed) if allowed or policy == 0 or native_worker else []
                if not allowed and kind in ['fetch-same-origin', 'xhr-false']:
                    want = []
            if kind == 'fetch-omit':
                want = []
            check(sent == want, 'cookies match permission, SameSite and privacy policy', detail + [dict(sent=sent, expected=want)])
    return dict(checks=len(checks), failures=[check for check in checks if not check['ok']], unsupported=unsupported)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    report = check_matrix(json.loads(args.results.read_text()))
    args.results.with_name('extra-matrix-checks.json').write_text(json.dumps(report, indent=2))
    print('Supplementary matrix checks:', report['checks'], 'FAILURES:', len(report['failures']))
    for failure in report['failures'][:30]:
        print(failure)
    return bool(report['failures'])


if __name__ == '__main__':
    raise SystemExit(main())
