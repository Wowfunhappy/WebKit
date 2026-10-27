#!/usr/bin/env python3
# The system proxy route's failover: CFNetwork answers a PAC file's "PROXY a; PROXY b" with both servers in order,
# and a load or WebSocket whose first server is down reaches its host through the next, as stock CFNetwork does.
#
# Needs proxy.py and server.py running (the proxies on 8856..8860, the pages on 8843) and sudo without a password.
# The primary network service's automatic proxy configuration is pointed at a PAC file this script serves on
# 127.0.0.1:8862: .proxy-test hosts get "PROXY 127.0.0.1:8859; PROXY 127.0.0.1:8856" (nothing listens on 8859), and
# every other host the route the service's own settings give it, so browsing keeps working while the check runs.
# The service's settings are put back on exit. Safari is opened on pages/system-proxy.html and the page's
# window.__results printed; the exit status is the number of failures.

import http.server
import json
import re
import subprocess
import sys
import threading
import time
import urllib.request

PAC_PORT = 8862
PAGE = 'http://127.0.0.1:8843/system-proxy.html'


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def primary_service():
    interface = re.search(r'interface: (\S+)', run('route', '-n', 'get', 'default')).group(1)
    order = run('networksetup', '-listnetworkserviceorder')
    for name, device in re.findall(r'\(\d+\) (.+)\n\(Hardware Port: .+, Device: (\S+)\)', order):
        if device == interface:
            return name
    raise SystemExit(f'no network service for {interface}')


def system_settings():
    text = run('scutil', '--proxy')
    values = dict(re.findall(r'^\s*(\w+) : (?!<array>)(.+)$', text, re.MULTILINE))
    exceptions = re.findall(r'^\s*\d+ : (.+)$', text.split('ExceptionsList', 1)[1].split('}', 1)[0], re.MULTILINE) if 'ExceptionsList' in text else []
    return values, exceptions


# The route the service's own settings give a URL, as a PAC function: its PAC file when it has one, else its manual
# proxies and their exceptions.
def previous_route_script(values, exceptions):
    if values.get('ProxyAutoConfigEnable') == '1' and values.get('ProxyAutoConfigURLString'):
        with urllib.request.urlopen(values['ProxyAutoConfigURLString']) as response:
            script = response.read().decode()
        return script.replace('FindProxyForURL', 'previousFindProxyForURL')
    lines = ['function previousFindProxyForURL(url, host) {']
    for exception in exceptions:
        if re.fullmatch(r'[\d.]+/\d+', exception):
            network, bits = exception.split('/')
            parts = (network.split('.') + ['0', '0', '0'])[:4]
            mask = '.'.join(str((0xffffffff << (32 - int(bits)) >> (24 - 8 * i)) & 0xff) for i in range(4))
            lines.append(f'    if (isInNet(host, "{".".join(parts)}", "{mask}")) return "DIRECT";')
        else:
            lines.append(f'    if (shExpMatch(host, {json.dumps(exception)})) return "DIRECT";')
    for scheme, key in (('https:', 'HTTPS'), ('http:', 'HTTP')):
        if values.get(f'{key}Enable') == '1':
            lines.append(f'    if (url.substring(0, {len(scheme)}) == "{scheme}") return "PROXY {values[key + "Proxy"]}:{values[key + "Port"]}";')
    if values.get('SOCKSEnable') == '1':
        lines.append(f'    return "SOCKS {values["SOCKSProxy"]}:{values["SOCKSPort"]}";')
    lines.append('    return "DIRECT";')
    lines.append('}')
    return '\n'.join(lines)


def serve(script):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = script.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-ns-proxy-autoconfig')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *arguments):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', PAC_PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def safari(script):
    return subprocess.run(['osascript', '-e', script], capture_output=True, text=True).stdout.strip()


def main():
    service = primary_service()
    values, exceptions = system_settings()
    script = previous_route_script(values, exceptions) + '''
function FindProxyForURL(url, host) {
    if (dnsDomainIs(host, ".proxy-test"))
        return "PROXY 127.0.0.1:8859; PROXY 127.0.0.1:8856";
    return previousFindProxyForURL(url, host);
}
'''
    serve(script)
    previous_url = run('networksetup', '-getautoproxyurl', service)
    previous_enabled = 'Enabled: Yes' in previous_url
    previous_address = re.search(r'URL: (.*)', previous_url).group(1).strip()
    manual = {}
    for kind in ('webproxy', 'securewebproxy', 'socksfirewallproxy'):
        manual[kind] = 'Enabled: Yes' in run('networksetup', f'-get{kind}', service)
    urllib.request.urlopen('http://127.0.0.1:8856/reset').read()
    failures = 0
    try:
        run('sudo', '-n', 'networksetup', '-setautoproxyurl', service, f'http://127.0.0.1:{PAC_PORT}/failover.pac')
        run('sudo', '-n', 'networksetup', '-setautoproxystate', service, 'on')
        for kind, enabled in manual.items():
            if enabled:
                run('sudo', '-n', 'networksetup', f'-set{kind}state', service, 'off')
        time.sleep(2)
        safari(f'tell application "Safari" to open location "{PAGE}"')
        results = None
        deadline = time.time() + 60
        while time.time() < deadline:
            time.sleep(1)
            done = safari('tell application "Safari" to do JavaScript "String(window.__done === true)" in current tab of front window')
            if done == 'true':
                results = json.loads(safari('tell application "Safari" to do JavaScript "JSON.stringify(window.__results)" in current tab of front window'))
                break
        if results is None:
            print('FAIL the page did not finish')
            failures = 1
        else:
            for name, result in results.items():
                print(f'{"PASS" if result["pass"] else "FAIL"} {name}: {result["detail"]}')
                failures += not result['pass']
        print('proxy 8856 saw:', json.dumps([entry for entry in json.loads(urllib.request.urlopen('http://127.0.0.1:8856/log').read())
                                              if 'failover' in entry.get('host', '')]))
    finally:
        for kind, enabled in manual.items():
            if enabled:
                run('sudo', '-n', 'networksetup', f'-set{kind}state', service, 'on')
        # networksetup cannot clear the URL; a service that had none keeps this one, switched off.
        if previous_address != '(null)':
            run('sudo', '-n', 'networksetup', '-setautoproxyurl', service, previous_address)
        run('sudo', '-n', 'networksetup', '-setautoproxystate', service, 'on' if previous_enabled else 'off')
    print(f'system proxy failover: FAILED={failures}')
    return failures


if __name__ == '__main__':
    sys.exit(main())
