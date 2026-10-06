"""Own a temporary loopback realm, server, and test credentials for one run."""
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
KDC = '/System/Library/PrivateFrameworks/Heimdal.framework/Helpers/kdc'
CLIENT = str(Path(sys.argv[1]).resolve())
OUTPUT = Path(sys.argv[2]).resolve()
PRINCIPAL = 'webkit-' + uuid.uuid4().hex + '@WEBKIT.TEST'


def caches():
    result = subprocess.run(['/usr/bin/klist', '-l'], capture_output=True, text=True)
    return [match.group(0) for line in result.stdout.splitlines()
            if PRINCIPAL in line for match in re.finditer(r'API:[A-Fa-f0-9-]+', line)]


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


with tempfile.TemporaryDirectory(prefix='webkit-websocket-auth-') as directory:
    work = Path(directory)
    config = work / 'krb5.conf'
    config.write_text('''[libdefaults]
 default_realm = WEBKIT.TEST
 dns_lookup_kdc = false
 dns_lookup_realm = false
 rdns = false
[realms]
 WEBKIT.TEST = {
  kdc = 127.0.0.1:18988
 }
[domain_realm]
 localhost = WEBKIT.TEST
 127.0.0.1 = WEBKIT.TEST
[kdc]
 database = {
  dbname = db:''' + str(work / 'principal') + '''
  realm = WEBKIT.TEST
  mkey_file = ''' + str(work / 'm-key') + '''
 }
''')
    password = work / 'password'
    password.write_text('correct-password\n')
    keytab = work / 'service.keytab'
    env = dict(os.environ, KRB5_CONFIG=str(config), KRB5CCNAME='API:',
               KRB5_KTNAME=str(keytab), WEBSOCKET_AUTH_WORK=str(work),
               WEBSOCKET_KERBEROS_PRINCIPAL=PRINCIPAL)
    admin = ['/usr/sbin/kadmin', '-l', '-c', str(config), '-r', 'WEBKIT.TEST']
    children = []
    try:
        subprocess.run(admin + ['init', '--realm-max-ticket-life=1h',
                               '--realm-max-renewable-life=1h', '--bare', 'WEBKIT.TEST'], env=env, check=True)
        subprocess.run(admin + ['add', '--use-defaults', '--password=correct-password', PRINCIPAL], env=env, check=True)
        service = 'HTTP/127.0.0.1@WEBKIT.TEST'
        subprocess.run(admin + ['add', '--use-defaults', '--random-key', service], env=env, check=True)
        subprocess.run(admin + ['ext_keytab', '-k', str(keytab), service], env=env, check=True)
        with (OUTPUT / 'kdc.log').open('w') as kdc_log, (OUTPUT / 'server.log').open('w') as server_log:
            kdc = subprocess.Popen([KDC, '-c', str(config), '--no-sandbox', '--listen-on-network',
                                    '--addresses=127.0.0.1', '--ports=18988'], env=env, stdout=kdc_log, stderr=kdc_log)
            children.append(kdc)
            wait_for_server(kdc, 18988)
            server = subprocess.Popen([sys.executable, str(HERE / 'websocket-ntlm-server.py'), '18986'],
                                      env=env, stdout=server_log, stderr=server_log)
            children.append(server)
            wait_for_server(server, 18986)
            subprocess.run([CLIENT], env=env, check=True, timeout=40)
            subprocess.run(['/usr/bin/kinit', '--no-change-default', '--password-file=' + str(password), PRINCIPAL],
                           env=env, check=True, timeout=15)
            owned_caches = caches()
            if len(owned_caches) != 1:
                raise RuntimeError('fixture did not acquire one identifiable API cache')
            subprocess.run([CLIENT, 'ticket'], env=dict(env, KRB5CCNAME=owned_caches[0]), check=True, timeout=20)
            subprocess.run([CLIENT, 'password'], env=env, check=True, timeout=20)
            subprocess.run([CLIENT, 'cancel'], env=env, check=True, timeout=20)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)
        for cache in caches():
            subprocess.run(['/usr/bin/kdestroy', '-c', cache], check=True)
