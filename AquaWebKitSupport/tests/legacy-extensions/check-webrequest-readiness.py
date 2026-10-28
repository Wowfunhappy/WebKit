#!/usr/bin/env python3
"""Exercise blocking webRequest in Safari's WK1 global page and WK2 tabs.

prepare copies the fixture to --work/webrequest-readiness.safariextension. Install that
copy in Extension Builder. cert creates a two-day loopback certificate; trust it
with `sudo security add-trusted-cert -d -r trustRoot -k
/Library/Keychains/System.keychain <work>/cert.pem` and remove that trust/certificate
after testing. serve binds only loopback, on HTTP 8876 and HTTPS 8877.

Use configure --reload, then check for each case. The normal page fetches five
seconds after registration. startup creates a parser-blocking script after
registration. preload starts requests before registration and receives their
responses afterward; its early passive listener keeps the requests tracked.
module uses a classic listener script and an ES-module dependency. --filter,
--nonblocking and no-module select its controls. --header-schemes checks header
events on web requests and lifecycle events on extension resources.
failed removes the working global page to check receiving-end errors.
The check command asserts JS results, runtime replies, listener calls, and tab
loading/complete events. A test deadline reports failure. --wk2 also checks an extension tab's own fetch.
"""

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import plistlib
import re
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
from urllib.parse import urlsplit

EXTENSIONS = Path(os.environ.get('AQUAWEBKIT_EXTENSIONS_DIR', Path(__file__).resolve().parents[4] / 'AquaWebKit-Extensions'))
TEMPLATE = EXTENSIONS / 'webrequest-readiness.safariextension'
BODY = b'local webRequest probe\n' * 128
HTTP = 'http://127.0.0.1:8876'
HTTPS = 'https://127.0.0.1:8877'
PAGE = b'''<!doctype html><title>Local load complete</title>
<link rel="stylesheet" href="/asset.css"><script src="/asset.js"></script>
<h1>Local test page</h1><img src="/pixel.png">
<script>window.__pageLoaded=false; addEventListener('load',()=>{window.__pageLoaded=true});</script>'''


def osa(source):
    return subprocess.check_output(['osascript', '-e', source], text=True).strip()


def js(source, window):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(source)
               + ' in current tab of window id ' + str(window))


def value(source, window):
    result = js('JSON.stringify((' + source + '))', window)
    return json.loads(result) if result not in ('', 'missing value') else None


def wait_until(function, description, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = function()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('No ' + description)


def new_window(url):
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    return int(osa('tell application "Safari" to get id of window 1'))


def reload_extension():
    osa('''tell application "System Events" to tell process "Safari"
 if not (exists window "Extension Builder") then
  click menu item "Show Extension Builder" of menu "Develop" of menu bar 1
  delay 0.5
 end if
 set foundEntry to false
 repeat with entry in groups of group 1 of UI element 1 of scroll area 1 of window "Extension Builder"
  if exists static text "Local webRequest Readiness" of entry then
   click static text "Local webRequest Readiness" of entry
   set foundEntry to true
   exit repeat
  end if
 end repeat
 if not foundEntry then error "Extension Builder requires the Local webRequest Readiness fixture."
 delay 0.3
 click button "Reload" of UI element 2 of group 2 of UI element 1 of scroll area 1 of window "Extension Builder"
 click button 1 of window "Extension Builder"
end tell''')


def configure(args):
    extension = args.work / 'webrequest-readiness.safariextension'
    plist_path = extension / 'Info.plist'
    plist = plistlib.loads(plist_path.read_bytes())
    plist['Chrome']['Global Page'] = 'global.html'
    plist_path.write_bytes(plistlib.dumps(plist))
    base = HTTPS if args.scheme == 'https' else HTTP
    urls = {'all': ['<all_urls>'], 'extension': ['safari-extension://*/*'],
            'web': ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*']}[args.filter]
    config = dict(probeEvent=args.event, probeBase=base, probeVerdict=args.verdict,
                  probeMode=args.mode, probeURLs=urls, probeBlocking=not args.nonblocking)
    script = (TEMPLATE / 'global.js').read_text()
    for name, val in config.items():
        script, count = re.subn('^const ' + name + r' = .*;$',
                                lambda match: 'const ' + name + ' = ' + json.dumps(val) + ';',
                                script, flags=re.MULTILINE)
        assert count == 1, name
    (extension / 'global.js').write_text(script)
    html = '<script src="global.js"></script>\n'
    if args.mode == 'module':
        html = (TEMPLATE / 'global.html').read_text()
    elif args.mode == 'startup':
        html += "<script>document.write('<scr' + 'ipt src=\"" + base + "/bootstrap.js?dynamic\"></scr' + 'ipt>');</script>\n"
    elif args.mode == 'preload':
        html = ('<!doctype html><meta charset="utf-8">\n'
                '<script>browser.webRequest.onBeforeRequest.addListener(() => {}, {urls:["<all_urls>"]});</script>\n'
                '<script src="' + base + '/gate.js"></script>\n'
                '<script src="global.js"></script>\n'
                '<script src="' + base + '/bootstrap.js?delayed"></script>\n')
    if args.mode == 'failed':
        (extension / 'global.html').unlink(missing_ok=True)
    else:
        (extension / 'global.html').write_text(html)
    if args.reload:
        reload_extension()
    print(json.dumps(config), flush=True)


def certificate(work):
    config = work / 'cert.cnf'
    config.write_text('''[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=AquaWebKit Local webRequest Test
[ext]
subjectAltName=IP:127.0.0.1,DNS:localhost
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
''')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                    '-config', str(config), '-keyout', str(work / 'key.pem'), '-out', str(work / 'cert.pem')], check=True)


def serve(work):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            with lock:
                with (work / 'server.jsonl').open('a') as log:
                    log.write(json.dumps(dict(time=time.time(), path=self.path, port=self.server.server_port)) + '\n')
            status, content_type = 200, 'text/plain; charset=utf-8'
            if path == '/driver.html':
                body, content_type = (TEMPLATE / 'driver.html').read_bytes(), 'text/html; charset=utf-8'
            elif path == '/data.txt':
                body = BODY
            elif path == '/page.html':
                body, content_type = PAGE, 'text/html; charset=utf-8'
            elif path in ('/gate.js', '/bootstrap.js'):
                if path == '/gate.js' or 'delayed' in self.path:
                    time.sleep(2 if path == '/gate.js' else 3)
                variable = '__gatePassed' if path == '/gate.js' else '__bootstrapExecuted'
                body = ('window.' + variable + '=true;\n/*' + 'x' * 1024 + '*/').encode()
                content_type = 'application/javascript'
            elif path == '/asset.js':
                body, content_type = b'window.__assetLoaded=true;', 'application/javascript'
            elif path == '/asset.css':
                body, content_type = b'body { color:#123; background:#efe }', 'text/css'
            elif path == '/pixel.png':
                body = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK4QAAAAASUVORK5CYII=')
                content_type = 'image/png'
            else:
                status, body = 404, b'not found\n'
            self.send_response(status)
            for name, val in [('Content-Type', content_type), ('Content-Length', str(len(body))),
                              ('Cache-Control', 'no-store'), ('Access-Control-Allow-Origin', '*'),
                              ('Access-Control-Expose-Headers', 'X-Probe-Changed,X-WebRequest-Probe'),
                              ('X-WebRequest-Probe', 'original')]:
                self.send_header(name, val)
            self.end_headers()
            self.wfile.write(body)

    class Server(ThreadingHTTPServer):
        request_queue_size = 128

    http = Server(('127.0.0.1', 8876), Handler)
    https = Server(('127.0.0.1', 8877), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(work / 'cert.pem'), str(work / 'key.pem'))
    https.socket = context.wrap_socket(https.socket, server_side=True)
    threading.Thread(target=https.serve_forever, daemon=True).start()
    print('Serving HTTP 8876 and HTTPS 8877 on loopback', flush=True)
    try:
        http.serve_forever()
    finally:
        http.server_close()
        https.shutdown()
        https.server_close()


def check(args):
    results = dict(mode=args.mode, event=args.event, verdict=args.verdict, scheme=args.scheme)
    output = args.work / (args.label + '.json')
    driver = new_window(HTTP + '/driver.html?' + args.label)
    wait_until(lambda: js('typeof askProbe', driver) == 'function'
               and js('document.documentElement.getAttribute("data-webrequest-readiness-content")', driver) == 'ready', 'content script')

    def snapshot(op='snapshot'):
        request_id = int(float(js('askProbe(' + json.dumps(op) + ')', driver)))
        reply = wait_until(lambda: value('__webrequestReadinessReplies.find(x=>x.id===' + str(request_id) + ')', driver), 'runtime reply')
        assert 'error' not in reply, reply
        return reply['result']

    def fetched():
        state = snapshot()
        return state if state['fetches'] and all(f['settled'] for f in state['fetches']) else None

    def assert_fetch(state):
        assert state['domContentLoaded'] and not state['errors'], state
        assert (state['event'], state['mode'], state['verdict']) == (args.event, args.mode, args.verdict), state
        for fetch in state['fetches']:
            assert fetch['settled'], fetch
            if args.verdict == 'cancel':
                assert 'error' in fetch and 'status' not in fetch, fetch
            else:
                assert fetch['status'] == 200 and fetch['bodyOK'] and fetch['bodyLength'] == len(BODY), fetch
                if args.verdict == 'headers':
                    assert fetch['changedHeader'] == 'yes', fetch
        assert any(call['event'] == args.event and '/data.txt?' in call['url'] for call in state['listenerCalls']), state
        if args.mode in ('startup', 'preload'):
            assert state['bootstrapExecuted'], state
            if args.event == 'onHeadersReceived' or args.mode == 'startup':
                assert any(call['event'] == args.event and '/bootstrap.js?' in call['url'] for call in state['listenerCalls']), state

    try:
        results['automatic'] = wait_until(fetched, 'automatic fetch settlement')
        assert_fetch(results['automatic'])
        snapshot('fetch')
        results['messageFetch'] = wait_until(fetched, 'message fetch settlement')
        assert_fetch(results['messageFetch'])
        assert len(results['messageFetch']['fetches']) == 2
        assert results['messageFetch']['messages'] > results['automatic']['messages']
        results['pages'] = []
        for base in (HTTP, HTTPS):
            url = base + '/page.html?' + args.label
            window = new_window(url)
            wait_until(lambda: value('window.__pageLoaded && window.__assetLoaded && document.readyState==="complete"', window), 'tab and subresource load')
            def completed():
                state = snapshot()
                return state if any(u['url'] == url and u['status'] == 'complete' for u in state['updates']) else None
            state = wait_until(completed, 'complete tab event')
            updates = [u for u in state['updates'] if u['url'] == url]
            assert any(u['status'] == 'loading' for u in updates), updates
            results['pages'].append(dict(url=url, updates=updates))
            osa('tell application "Safari" to close window id ' + str(window))
        if args.wk2:
            state = snapshot()
            window = new_window(state['viewURL'])
            wait_until(lambda: value('window.__webrequestReadiness && __webrequestReadiness.fetches.length && __webrequestReadiness.fetches[0].settled', window), 'WK2 extension fetch')
            results['wk2'] = value('__webrequestReadiness', window)
            assert_fetch(results['wk2'])
            if args.resource_stages:
                js('runResourceChecks(); true', window)
                results['wk2Resources'] = wait_until(lambda: resource_stages(value('__webrequestReadiness', window)), 'WK2 extension resource events')
            assert any(c['tabId'] != -1 and '/data.txt?' in c['url'] for c in results['wk2']['listenerCalls']), results['wk2']
            osa('tell application "Safari" to close window id ' + str(window))
        results['final'] = snapshot()
        assert results['final']['messages'] > results['messageFetch']['messages']
        results['passed'] = True
        print('PASS ' + args.label, flush=True)
    finally:
        output.write_text(json.dumps(results, indent=2))
        osa('tell application "Safari" to close window id ' + str(driver))


def inspect_global_page():
    osa('''tell application "System Events" to tell process "Safari"
 if not (exists window "Extension Builder") then
  click menu item "Show Extension Builder" of menu "Develop" of menu bar 1
  delay 0.5
 end if
 set foundEntry to false
 repeat with entry in groups of group 1 of UI element 1 of scroll area 1 of window "Extension Builder"
  if exists static text "Local webRequest Readiness" of entry then
   click static text "Local webRequest Readiness" of entry
   set foundEntry to true
   exit repeat
  end if
 end repeat
 if not foundEntry then error "Extension Builder requires the Local webRequest Readiness fixture."
 delay 0.3
 click button "Inspect Global Page" of UI element 2 of row 17 of table 1 of UI element 1 of scroll area 1 of window "Extension Builder"
 delay 0.5
end tell''')


def global_value(expression):
    token = str(time.monotonic_ns())
    command = 'btoa(JSON.stringify({token:' + json.dumps(token) + ',value:(' + expression + ')}))'
    prefix = '''tell application "System Events" to tell process "Safari"
 set inspector to first window whose name contains "org.webkit.local-webrequest-readiness"
 set content to group "Content" of UI element 1 of scroll area 1 of inspector
'''
    osa(prefix + ''' perform action "AXRaise" of inspector
 set frontmost to true
 set focused of text area 1 of content to true
 keystroke ''' + json.dumps(command) + '''
 key code 36
end tell''')

    def result():
        raw = osa(prefix + 'return name of static texts of every group of group 2 of content\nend tell')
        for encoded in re.findall(r'[A-Za-z0-9+/=]{20,}', raw):
            try:
                decoded = json.loads(base64.b64decode(encoded, validate=True))
            except ValueError:
                continue
            if isinstance(decoded, dict) and decoded.get('token') == token:
                return decoded
        return None

    return wait_until(result, 'Inspector evaluation ' + token, seconds=10)['value']


def check_module(args):
    results = dict(mode=args.mode, event=args.event, filter=args.filter,
                   blocking=not args.nonblocking)
    output = args.work / (args.label + '.json')
    windows = []
    try:
        inspect_global_page()
        state = wait_until(lambda: global_value('window.__webrequestReadiness'), 'global probe')
        results['first'] = state
        assert (state['event'], state['mode'], state['blocking']) == (args.event, args.mode, not args.nonblocking), state
        for base in (HTTP, HTTPS):
            url = base + '/page.html?' + args.label
            windows.append((new_window(url), url))
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            state = global_value('__webrequestReadiness')
            if state['fetches'] and all(f['settled'] for f in state['fetches']) and state['domContentLoaded']:
                break
            time.sleep(.5)
        results['global'] = state
        results['pages'] = []
        for window, url in windows:
            loaded = value('!!(window.__pageLoaded && window.__assetLoaded && document.readyState === "complete")', window)
            results['pages'].append(dict(url=url, loaded=loaded, readyState=js('document.readyState', window)))
        assert state['domContentLoaded'] and not state['errors'], state
        assert state['m1Executed'] == (args.mode == 'module') and state['m2Executed'] == (args.mode == 'module'), state
        assert state['fetches'] and all(f.get('status') == 200 and f.get('bodyOK') and f['settled'] for f in state['fetches']), state
        assert all(p['loaded'] for p in results['pages']), results['pages']
        own_calls = [c for c in state['listenerCalls'] if c['url'].startswith('safari-extension:')]
        if args.mode == 'module':
            assert any(c['event'] == 'onBeforeRequest' and c['url'].endswith('/m2.js') for c in own_calls), own_calls
            for name in ('onResponseStarted', 'onCompleted'):
                assert any(c['event'] == name and c['url'].endswith('/m2.js') for c in own_calls), (name, own_calls)
        if args.header_schemes:
            assert not any(c['event'] in ('onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived') for c in own_calls), own_calls
            for name in ('onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived'):
                assert any(c['event'] == name and '/data.txt?' in c['url'] for c in state['listenerCalls']), name
        if args.resource_stages:
            global_value('(runResourceChecks(), true)')
            results['resources'] = wait_until(lambda: resource_stages(global_value('__webrequestReadiness')), 'extension resource events')
        results['runtime'] = runtime_snapshot(args)
        assert results['runtime']['domContentLoaded'] and results['runtime']['messages'] > 0
        results['passed'] = True
        print('PASS ' + args.label, flush=True)
    finally:
        output.write_text(json.dumps(results, indent=2))
        for window, url in windows:
            osa('tell application "Safari" to close window id ' + str(window))


def resource_stages(state):
    results = state.get('resources', {})
    if not results.get('done'):
        return None
    calls = [c for c in state['listenerCalls'] if c['url'].startswith('safari-extension:')]
    if not any(c['event'] == 'onCompleted' and 'sync-probe' in c['url'] for c in calls):
        return None
    assert not any(c['event'] in ('onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived') for c in calls), calls
    assert 'export const value = 42' in results['m2.js?async-probe']['body'], results
    assert 'export const value = 42' in results['redirect-probe.js']['body'], results
    assert 'export const value = 42' in results['sync']['body'], results
    assert 'error' in results['missing-probe.js'], results
    assert any(c['event'] == 'onBeforeRedirect' and c.get('statusCode') == 307 and '/redirect-probe.js' in c['url'] for c in calls), calls
    assert any(c['event'] == 'onErrorOccurred' and '/missing-probe.js' in c['url'] for c in calls), calls
    return dict(results=results, calls=calls)


def runtime_snapshot(args, expect_error=False):
    driver = new_window(HTTP + '/driver.html?' + args.label)
    try:
        wait_until(lambda: js('typeof askProbe', driver) == 'function'
                   and js('document.documentElement.getAttribute("data-webrequest-readiness-content")', driver) == 'ready', 'content script')
        identifier = int(float(js('askProbe("snapshot")', driver)))
        reply = wait_until(lambda: value('__webrequestReadinessReplies.find(x=>x.id===' + str(identifier) + ')', driver), 'runtime reply')
        if expect_error:
            assert reply.get('error') == 'Error: Could not establish connection. Receiving end does not exist.', reply
            return reply
        assert 'error' not in reply, reply
        return reply['result']
    finally:
        osa('tell application "Safari" to close window id ' + str(driver))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=['prepare', 'cert', 'serve', 'configure', 'check'])
    parser.add_argument('--work', type=Path, default=Path(__file__).resolve().parent / 'build/webrequest-readiness')
    parser.add_argument('--mode', choices=['normal', 'startup', 'preload', 'module', 'no-module', 'failed'], default='normal')
    parser.add_argument('--event', choices=['onBeforeRequest', 'onHeadersReceived', 'onBeforeSendHeaders'], default='onHeadersReceived')
    parser.add_argument('--verdict', choices=['undefined', 'promise', 'cancel', 'headers'], default='undefined')
    parser.add_argument('--scheme', choices=['http', 'https'], default='https')
    parser.add_argument('--filter', choices=['all', 'extension', 'web'], default='all')
    parser.add_argument('--nonblocking', action='store_true')
    parser.add_argument('--header-schemes', action='store_true')
    parser.add_argument('--label', default='results')
    parser.add_argument('--reload', action='store_true')
    parser.add_argument('--wk2', action='store_true')
    parser.add_argument('--resource-stages', action='store_true')
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    if args.command == 'prepare':
        shutil.copytree(TEMPLATE, args.work / 'webrequest-readiness.safariextension', dirs_exist_ok=True)
        configure(args)
    elif args.command == 'cert':
        certificate(args.work)
    elif args.command == 'serve':
        serve(args.work)
    elif args.command == 'configure':
        configure(args)
    elif args.mode == 'failed':
        replies = [runtime_snapshot(args, expect_error=True) for _ in range(2)]
        (args.work / (args.label + '.json')).write_text(json.dumps(dict(passed=True, replies=replies), indent=2))
        print('PASS ' + args.label)
    elif args.mode in ('module', 'no-module'):
        check_module(args)
    else:
        check(args)


if __name__ == '__main__':
    main()
