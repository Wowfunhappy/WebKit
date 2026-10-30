#!/usr/bin/env python3
"""Safari 7 local cookie matrix. Fixtures live in AquaWebKit-Extensions.

prepare writes All/Some/None/HTTP-only fixtures. Install with Extension Builder.
run records attachment under each Safari privacy policy, then restores the policy.
cookie-server.py supplies HTTP/HTTPS and WS/WSS; its certificate must be trusted.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

HERE = Path(__file__).resolve().parent
EXTENSIONS = HERE.parents[3] / 'AquaWebKit-Extensions'
WORK = Path(os.environ.get('AQUAWEBKIT_COOKIE_TEST_DIR', HERE / 'results/cookies')).expanduser().resolve()
POLICIES = {0: 'Never', 2: 'From third parties and advertisers', 1: 'Always'}


def osa(source):
    return subprocess.check_output(['osascript', '-e', source], text=True).strip()


def js(window, source):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(source)
               + ' in current tab of window id ' + str(window))


def wait(function, description, timeout=40):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = function()
        if value:
            return value
        time.sleep(.2)
    raise RuntimeError('Timed out: ' + description)


def window(url):
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    result = int(osa('tell application "Safari" to get id of window 1'))
    try:
        wait(lambda: js(result, 'document.readyState === \"complete\" && location.href === ' + json.dumps(url)) == 'true', url)
    except Exception:
        close(result)
        raise
    return result


def close(number):
    osa('tell application "Safari" to close window id ' + str(number))


def current_policy():
    selected = osa('''tell application "Safari" to activate
tell application "System Events" to tell process "Safari"
 click menu item "Preferences…" of menu "Safari" of menu bar 1
 click button "Privacy" of toolbar 1 of window 1
 set selectedPolicy to ""
 repeat with choice in radio buttons of radio group 1 of group 1 of group 1 of window "Privacy"
  if value of choice is 1 then set selectedPolicy to name of choice
 end repeat
 click button 1 of window "Privacy"
 return selectedPolicy
end tell''')
    for value, label in POLICIES.items():
        if selected == label:
            return value
    raise RuntimeError('Unknown Safari cookie policy: ' + selected)


def policy(value):
    osa('''tell application "Safari" to activate
tell application "System Events" to tell process "Safari"
 click menu item "Preferences…" of menu "Safari" of menu bar 1
 click button "Privacy" of toolbar 1 of window 1
 click radio button ''' + json.dumps(POLICIES[value]) + ''' of radio group 1 of group 1 of group 1 of window "Privacy"
 click button 1 of window "Privacy"
end tell''')


def prepare():
    template = plistlib.loads((EXTENSIONS / 'api-test.safariextension/Info.plist').read_bytes())
    for name, access, secure in [('all', 'All', True), ('some', 'Some', True), ('none', 'None', False), ('http-only', 'Some', False)]:
        path = EXTENSIONS / ('cookie-' + name + '.safariextension')
        path.mkdir(exist_ok=True)
        info = dict(template)
        info.update(CFBundleDisplayName='Aqua Cookie ' + name, CFBundleIdentifier='org.webkit.aqua-cookie-' + name)
        info['Chrome'] = {'Global Page': 'global.html'}
        if name == 'all':
            info['Chrome']['Bars'] = [{'File':'bar.html', 'Filename':'bar.html', 'Identifier':'cookieBar', 'Label':'Cookie fixture'}]
            info['Chrome']['Popovers'] = [{'Filename':'popover.html', 'Identifier':'cookiePopover', 'Width':240.0, 'Height':100.0}]
            info['Chrome']['Toolbar Items'] = [{'Identifier':'cookiePopupButton', 'Image':'button.png', 'Label':'Cookie Popup', 'Popover':'cookiePopover'}]
            (path / 'button.png').write_bytes((EXTENSIONS / 'api-test.safariextension/button.png').read_bytes())
        info['Content'] = {'Scripts': {}}
        info['Permissions'] = {'Website Access': {'Level': access, 'Include Secure Pages': secure, 'Allowed Domains': ['localhost', '*.ext-cookie.test']}}
        (path / 'Info.plist').write_bytes(plistlib.dumps(info))
        (path / 'exercise.js').write_text((HERE / 'pages/cookie-exercise.js').read_text())
        (path / 'global.html').write_text('<!doctype html><script src="exercise.js"></script><script src="global.js"></script>')
        (path / 'global.js').write_text('''browser.runtime.onMessage.addListener(message => {
    if (message.cookieTest === 'global') return cookieExercise(message.options);
    if (message.cookieTest === 'global-websocket') return cookieWebSocketProbe(message.options);
    if (message.cookieTest === 'global-websocket-control') {
        if (message.action === 'close') window.cookieProbeSocket.close();
        else setTimeout(() => location.replace('global.html?wsNavigation=' + message.id), 0);
        return Promise.resolve({queued:true});
    }
    if (message.cookieTest === 'global-navigation') return cookieParentNavigation(message.options);
    if (message.cookieTest === 'global-response-redirect') return cookieResponseRedirect(message.options);
    if (message.cookieTest === 'global-worker') return cookieWorker(message.options, false);
    if (message.cookieTest === 'global-shared') return cookieWorker(message.options, true);
    if (message.cookieTest === 'ping') return Promise.resolve({href:location.href});
});
fetch('http://localhost:8877/report', {method:'POST', headers:{'Content-Type':'application/json'},
body:JSON.stringify({ready:''' + json.dumps(name) + ''', page:new URL('page.html', location.href).href, navigation:new URL(location.href).searchParams.get('wsNavigation')})});
''')
        (path / 'page.html').write_text('<!doctype html><title>Aqua Cookie ' + name + '</title><script src="exercise.js"></script><h1>Aqua Cookie ' + name + '</h1>')
        (path / 'bar.html').write_text('<!doctype html><script src="exercise.js"></script><script src="bar.js"></script>Cookie fixture')
        (path / 'bar.js').write_text("browser.runtime.onMessage.addListener(m => m.cookieTest === 'bar' ? cookieExercise(m.options) : undefined);")
        (path / 'popover.html').write_text('<!doctype html><script src="exercise.js"></script><script src="popover.js"></script>Cookie popover fixture')
        (path / 'popover.js').write_text("browser.runtime.onMessage.addListener(m => m.cookieTest === 'popover' ? cookieExercise(m.options) : undefined);")
        (path / 'shared-worker.js').write_text("importScripts('exercise.js'); onconnect = e => { const p=e.ports[0]; p.onmessage=async e=>p.postMessage(await cookieExercise(e.data)); p.start(); };")
        (path / 'worker.js').write_text("importScripts('exercise.js'); onmessage = async e => postMessage(await cookieExercise(e.data));")


def roots():
    result = {}
    for line in (WORK / 'server.jsonl').read_text().splitlines():
        try:
            row = json.loads(line).get('report', {})
            if 'ready' in row:
                result[row['ready']] = row['page']
        except ValueError:
            pass
    return result


def reload_fixtures(fixtures):
    osa('tell application "Safari" to activate')
    osa('tell application "System Events" to tell process "Safari" to if not (exists window "Extension Builder") then click menu item "Show Extension Builder" of menu "Develop" of menu bar 1')
    wait(lambda: osa('tell application "System Events" to tell process "Safari" to exists group 1 of UI element 1 of scroll area 1 of window "Extension Builder"') == 'true', 'Extension Builder ready')
    try:
        for fixture in fixtures:
            old = roots().get(fixture)
            title = 'Aqua Cookie ' + fixture
            osa('''tell application "System Events" to tell process "Safari"
 repeat with entry in groups of group 1 of UI element 1 of scroll area 1 of window "Extension Builder"
  if exists static text ''' + json.dumps(title) + ''' of entry then
   click static text ''' + json.dumps(title) + ''' of entry
   exit repeat
  end if
 end repeat
 delay 0.3
 perform action "AXPress" of button "Reload" of UI element 2 of group 2 of UI element 1 of scroll area 1 of window "Extension Builder"
end tell''')
            wait(lambda: roots().get(fixture) and roots()[fixture] != old, 'fresh ' + fixture + ' registration')
            print('Reloaded:', fixture, flush=True)
    finally:
        osa('tell application "System Events" to tell process "Safari" to click button 1 of window "Extension Builder"')


def exercise(number, expression):
    js(number, 'window.__cookieResult=null; Promise.resolve(' + expression + ').then(v=>window.__cookieResult=JSON.stringify(v===undefined?{noResponse:true}:v),e=>window.__cookieResult=JSON.stringify({error:String(e)})); "started"')
    return json.loads(wait(lambda: js(number, 'window.__cookieResult || ""'), 'cookie exercise', 80))


def run(args):
    pages = roots()
    missing = set(args.fixtures) - pages.keys()
    if missing:
        raise RuntimeError('Install fixtures first: ' + str(missing))
    WORK.mkdir(parents=True, exist_ok=True)
    output = WORK / (args.phase + '.json')
    results = []
    def record(row):
        results.append(row)
        output.write_text(json.dumps(results, indent=2))
        print(json.dumps({k:v for k,v in row.items() if k != 'result'}), flush=True)
    saved_policy = current_policy()
    try:
        policy(0)
        for host in ['localhost', '127.0.0.1']:
            for scheme, port in [('http', 8877), ('https', 8878)]:
                number = window(scheme + '://' + host + ':' + str(port) + '/seed')
                record(dict(fixture='web', context='seed', base=scheme + '://' + host, policy=0,
                            result=js(number, 'document.body.innerText')))
                close(number)
        for value in args.policies:
            policy(value)
            for fixture in args.fixtures:
                number = window(pages[fixture])
                for scheme, port in [('http', 8877), ('https', 8878)]:
                    for host in ['localhost', '127.0.0.1']:
                        base = scheme + '://' + host + ':' + str(port)
                        for context in ['global', 'tab']:
                            options = dict(base=base, id='-'.join([args.phase, str(value), fixture, context, scheme, host]), redirects=(host == 'localhost'))
                            expression = ('browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global', options=options)) + ')' if context == 'global' else 'cookieExercise(' + json.dumps(options) + ')')
                            record(dict(fixture=fixture, context=context, policy=value, base=base, result=exercise(number, expression)))
                close(number)
                number = window('http://localhost:8877/cookie-frame.html')
                js(number, 'window.cookieFrame=addCookieFrame(' + json.dumps(pages[fixture]) + '); "created"')
                wait(lambda: js(number, 'document.querySelector("iframe").cookieLoaded') == 'true', 'iframe window')
                for host in ['localhost', '127.0.0.1']:
                    options = dict(base='http://' + host + ':8877', id='-'.join([args.phase, str(value), fixture, 'iframe', host]))
                    js(number, 'cookieResults=[]; cookieFrame.contentWindow.postMessage(' + json.dumps(dict(cookieTest='exercise', options=options)) + ', "*"); "sent"')
                    result = json.loads(wait(lambda: js(number, 'cookieResults.length ? JSON.stringify(cookieResults[0]) : ""'), 'extension iframe', 60))
                    record(dict(fixture=fixture, context='extension-iframe', policy=value, base=options['base'], result=result))
                close(number)
            number = window('http://localhost:8877/cookie-frame.html')
            for host in ['localhost', '127.0.0.1']:
                options = dict(base='http://' + host + ':8877', id=args.phase + '-web-' + str(value) + '-' + host)
                record(dict(fixture='web', context='web', policy=value, base=options['base'], result=exercise(number, 'cookieExercise(' + json.dumps(options) + ')')))
            js(number, 'window.cookieFrame=addCookieFrame("http://127.0.0.1:8877/cookie-frame.html"); "created"')
            wait(lambda: js(number, 'cookieFrame.cookieLoaded') == 'true', 'web iframe load')
            options = dict(base='http://127.0.0.1:8877', id=args.phase + '-web-cross-site-iframe-' + str(value))
            js(number, 'cookieResults=[]; cookieFrame.contentWindow.postMessage(' + json.dumps(dict(cookieTest='exercise', options=options)) + ', "*"); "sent"')
            result = json.loads(wait(lambda: js(number, 'cookieResults.length ? JSON.stringify(cookieResults[0]) : ""'), 'web iframe', 60))
            record(dict(fixture='web', context='web-cross-site-iframe', policy=value, base=options['base'], result=result))
            close(number)
    finally:
        policy(saved_policy)


if __name__ == '__main__':
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'reload', 'run'])
    parser.add_argument('--phase', default='verified')
    parser.add_argument('--fixtures', nargs='+', default=['all', 'some', 'none', 'http-only'])
    parser.add_argument('--policies', nargs='+', type=int, default=[0, 2, 1])
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare()
    elif args.command == 'reload':
        reload_fixtures(args.fixtures)
    else:
        run(args)
