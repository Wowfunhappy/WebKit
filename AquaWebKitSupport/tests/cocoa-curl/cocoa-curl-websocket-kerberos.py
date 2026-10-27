#!/usr/bin/env python3
"""Run cocoa-curl-websocket-auth with a temporary loopback Kerberos realm and its authentication server.

  cocoa-curl-websocket-kerberos.py <cocoa-curl-websocket-auth program> [args...]

The realm WEBKIT.TEST has its KDC on 127.0.0.1:18993, a principal made for the run with the password
"correct-password", and HTTP/127.0.0.1 for cocoa-curl-websocket-auth-server.py on 18986. A page WebSocket
authenticates from the network process, which takes no environment from its client, so for the length of the run the
realm is in ~/Library/Preferences/edu.mit.Kerberos, the user's own Kerberos configuration, and the Negotiate ticket
case's ticket is in the user's default credentials cache. The file is put back as it was, and every cache holding the
run's principal destroyed, on exit. Output goes to $COCOA_CURL_FIXTURES (the suite's fixture directory) when set.
"""
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
KDC = '/System/Library/PrivateFrameworks/Heimdal.framework/Helpers/kdc'
CLIENT = [str(Path(sys.argv[1]).resolve())] + sys.argv[2:]
OUTPUT = Path(os.environ.get('COCOA_CURL_FIXTURES', tempfile.gettempdir())).resolve()
PRINCIPAL = 'webkit-' + uuid.uuid4().hex + '@WEBKIT.TEST'
USER_CONFIG = Path.home() / 'Library' / 'Preferences' / 'edu.mit.Kerberos'
CLIENT_CONFIG = '''[libdefaults]
 default_realm = WEBKIT.TEST
 dns_lookup_kdc = false
 dns_lookup_realm = false
 rdns = false
[realms]
 WEBKIT.TEST = {
  kdc = 127.0.0.1:18993
 }
[domain_realm]
 localhost = WEBKIT.TEST
 127.0.0.1 = WEBKIT.TEST
'''


def caches():
    result = subprocess.run(['/usr/bin/klist', '-l'], capture_output=True, text=True)
    return [match.group(0) for line in result.stdout.splitlines()
            if PRINCIPAL in line for match in re.finditer(r'API:[A-Fa-f0-9-]+', line)]


def destroy_caches():
    for cache in caches():
        subprocess.run(['/usr/bin/kdestroy', '-c', cache], check=False)


def wait_for_server(process, port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('fixture server exited; inspect ' + str(OUTPUT))
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError('fixture server did not start; inspect ' + str(OUTPUT))


def main():
    failures = 0
    with tempfile.TemporaryDirectory(prefix='webkit-websocket-auth-') as directory:
        work = Path(directory)
        config = work / 'krb5.conf'
        config.write_text(CLIENT_CONFIG + '''[kdc]
 database = {
  dbname = db:''' + str(work / 'principal') + '''
  realm = WEBKIT.TEST
  mkey_file = ''' + str(work / 'm-key') + '''
 }
''')
        password = work / 'password'
        password.write_text('correct-password\n')
        keytab = work / 'service.keytab'
        env = dict(os.environ, KRB5_CONFIG=str(config), KRB5_KTNAME=str(keytab), WEBSOCKET_AUTH_WORK=str(work),
                   WEBSOCKET_KERBEROS_PRINCIPAL=PRINCIPAL)
        admin = ['/usr/sbin/kadmin', '-l', '-c', str(config), '-r', 'WEBKIT.TEST']
        backup = work / 'edu.mit.Kerberos'
        had_user_config = USER_CONFIG.exists()
        if had_user_config:
            shutil.copy2(USER_CONFIG, backup)
        children = []
        try:
            subprocess.run(admin + ['init', '--realm-max-ticket-life=1h', '--realm-max-renewable-life=1h', '--bare', 'WEBKIT.TEST'], env=env, check=True)
            subprocess.run(admin + ['add', '--use-defaults', '--password=correct-password', PRINCIPAL], env=env, check=True)
            service = 'HTTP/127.0.0.1@WEBKIT.TEST'
            subprocess.run(admin + ['add', '--use-defaults', '--random-key', service], env=env, check=True)
            subprocess.run(admin + ['ext_keytab', '-k', str(keytab), service], env=env, check=True)
            USER_CONFIG.parent.mkdir(parents=True, exist_ok=True)
            USER_CONFIG.write_text(CLIENT_CONFIG)
            with (OUTPUT / 'websocket-kdc.log').open('w') as kdc_log, (OUTPUT / 'websocket-auth-server.log').open('w') as server_log:
                kdc = subprocess.Popen([KDC, '-c', str(config), '--no-sandbox', '--listen-on-network',
                                        '--addresses=127.0.0.1', '--ports=18993'], env=env, stdout=kdc_log, stderr=kdc_log)
                children.append(kdc)
                wait_for_server(kdc, 18993)
                server = subprocess.Popen([sys.executable, str(HERE / 'cocoa-curl-websocket-auth-server.py'), '18986'],
                                          env=env, stdout=server_log, stderr=server_log)
                children.append(server)
                wait_for_server(server, 18986)
                client_env = dict(os.environ, WEBSOCKET_KERBEROS_PRINCIPAL=PRINCIPAL)
                failures += subprocess.run(CLIENT, env=client_env, timeout=90).returncode != 0
                subprocess.run(['/usr/bin/kinit', '--password-file=' + str(password), PRINCIPAL], env=env, check=True, timeout=15)
                failures += subprocess.run(CLIENT + ['ticket'], env=client_env, timeout=40).returncode != 0
                destroy_caches()
                failures += subprocess.run(CLIENT + ['password'], env=client_env, timeout=40).returncode != 0
                destroy_caches()
                failures += subprocess.run(CLIENT + ['cancel'], env=client_env, timeout=40).returncode != 0
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
            destroy_caches()
            if had_user_config:
                shutil.copy2(backup, USER_CONFIG)
            elif USER_CONFIG.exists():
                USER_CONFIG.unlink()
    print('WebSocket authentication runs: FAILED=%d' % failures)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
