#!/usr/bin/env python3
"""Check Some/None/Some across Safari relaunches; restore the fixture and privacy policy."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess

os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
spec = importlib.util.spec_from_file_location('probe', str(Path(__file__).with_name('check-extension-cookies.py')))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def install():
    p.osa('tell application "Safari" to activate')
    p.osa('tell application "System Events" to tell process "Safari" to if not (exists window "Extension Builder") then click menu item "Show Extension Builder" of menu "Develop" of menu bar 1')
    p.wait(lambda: p.osa('tell application "System Events" to tell process "Safari" to exists group 1 of UI element 1 of scroll area 1 of window "Extension Builder"') == 'true', 'Extension Builder ready')
    p.osa('''tell application "System Events" to tell process "Safari"
 repeat with entry in groups of group 1 of UI element 1 of scroll area 1 of window "Extension Builder"
  if exists static text "Aqua Cookie some" of entry then
   click static text "Aqua Cookie some" of entry
   exit repeat
  end if
 end repeat
 delay 0.3
 perform action "AXPress" of button "Uninstall" of UI element 2 of group 2 of UI element 1 of scroll area 1 of window "Extension Builder"
 delay 0.3
 perform action "AXPress" of button "Install" of UI element 2 of group 2 of UI element 1 of scroll area 1 of window "Extension Builder"
 click button 1 of window "Extension Builder"
end tell''')


def safari_pids():
    return [int(line.split()[0]) for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
            if line.strip().endswith('/Safari.app/Contents/MacOS/Safari')]


def relaunch(label, save):
    old = safari_pids()
    assert old, 'Safari must be running before the relaunch'
    p.osa('tell application "Safari" to quit')
    checks = {}
    for pid in old:
        p.wait(lambda: subprocess.call(['kill', '-0', str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0,
               'Safari exit: ' + str(pid))
        checks[str(pid)] = 'kill -0 returned nonzero'
    subprocess.check_call(['open', '-a', 'Safari'])
    p.wait(lambda: safari_pids() and not set(safari_pids()).intersection(old), 'new Safari process')
    p.wait(lambda: p.osa('tell application "System Events" to tell process "Safari" to exists menu "Develop" of menu bar 1') == 'true', 'Safari menus')
    p.reload_fixtures(['some'])
    save(label + '-relaunch', dict(oldPIDs=old, exitChecks=checks, newPIDs=safari_pids(), root=p.roots()['some']))


def main():
    plist = p.EXTENSIONS / 'cookie-some.safariextension/Info.plist'
    original = plist.read_bytes()
    data = plistlib.loads(original)
    assert data['Permissions']['Website Access']['Level'] == 'Some', 'Start with the Some fixture installed from its canonical directory'
    saved_policy = p.current_policy()
    rows = []
    def save(label, result):
        rows.append(dict(label=label, result=result))
        (p.WORK / 'permission-lifecycle.json').write_text(json.dumps(rows, indent=2))
        print(label, json.dumps(result) if 'exitChecks' in result else '', flush=True)

    def exercise(label, expected):
        number = p.window(p.roots()['some'])
        try:
            for context in ['global', 'tab']:
                options = dict(base='http://localhost:8877', id='permission-' + label + '-' + context)
                expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global', options=options)) + ')'
                              if context == 'global' else 'cookieExercise(' + json.dumps(options) + ')')
                result = p.exercise(number, expression)
                save(label + '-' + context, result)
                kinds = {'fetch-include', 'fetch-post', 'xhr-true', 'websocket'}
                actual_kinds = set()
                for item in result.get('results', []):
                    if item['kind'] in kinds:
                        actual_kinds.add(item['kind'])
                        cookies = {n for n in item.get('value', {}).get('cookies', {}) if n.startswith('extck_h_')}
                        assert cookies == expected, (label, context, item)
                assert actual_kinds == kinds, (label, context, result)
        finally:
            p.close(number)

    all_cookies = {'extck_h_' + kind + suffix for kind in ['unspecified', 'none', 'lax', 'strict'] for suffix in ['', '_http']}
    ordinary = {name for name in all_cookies if '_lax' not in name and '_strict' not in name}
    revocation_failed = False
    try:
        p.policy(0)
        number = p.window('http://localhost:8877/seed')
        p.close(number)
        exercise('allowed', all_cookies)
        data['Permissions']['Website Access'] = {'Level': 'None'}
        plist.write_bytes(plistlib.dumps(data))
        install()
        relaunch('revoked', save)
        p.policy(0)
        try:
            exercise('revoked', ordinary)
        except AssertionError:
            revocation_failed = True
            save('revocation-failure', dict(traceRequired=True, fixture='None', message='Keep this Safari session for WebContent and Networking call-stack traces'))
            raise
        plist.write_bytes(original)
        install()
        relaunch('restored', save)
        p.policy(0)
        exercise('restored', all_cookies)
        save('complete', dict(passed=True, policy=saved_policy, checkedTransports=24))
    finally:
        try:
            if not revocation_failed and plist.read_bytes() != original:
                plist.write_bytes(original)
                install()
                relaunch('cleanup', save)
        finally:
            p.policy(saved_policy)


if __name__ == '__main__':
    main()
