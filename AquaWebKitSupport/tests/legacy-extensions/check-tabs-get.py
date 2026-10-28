#!/usr/bin/env python3
"""Check tabs.get references through hidden-tabs.safariextension on local pages.

Run server.py and install the sibling AquaWebKit-Extensions workspace's
hidden-tabs.safariextension in Safari's Extension Builder first.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time


BASE = 'http://localhost:8843/editing-actions.html?tabs-get='


def applescript(source):
    return subprocess.check_output(['osascript', '-e', source], text=True).strip()


def run(output):
    results = []
    token = str(time.time_ns())
    urls = {name: BASE + token + '-' + name for name in ['driver', 'a', 'b', 'c', 'navigated']}
    applescript('tell application "Safari" to make new document with properties {URL:'
               + json.dumps(urls['driver']) + '}')
    driver = applescript('tell application "Safari" to get id of window 1')

    def js(source):
        return applescript('tell application "Safari" to do JavaScript ' + json.dumps(source)
                           + ' in tab 1 of window id ' + driver)

    def request(operation, *args):
        js('window.__hiddenTabsResult=null; window.postMessage('
           + json.dumps(dict(hiddenTabs=operation, args=args)) + ', "*"); "sent"')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            reply = js('window.__hiddenTabsResult || ""')
            if reply:
                return json.loads(reply)
            time.sleep(0.1)
        raise RuntimeError('No extension answer: ' + operation)

    def call(operation, *args):
        reply = request(operation, *args)
        if 'error' in reply:
            raise RuntimeError(operation + ': ' + reply['error'])
        return reply.get('value')

    def check(name, ok, **data):
        row = dict(name=name, ok=bool(ok), **data)
        results.append(row)
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(row), flush=True)
        if not ok:
            raise AssertionError(name)

    def mapping(name):
        windows = call('mapping')
        tabs = [tab for window in windows for tab in window['tabs']]
        check(name, bool(tabs) and all(row['tab'] == row['numeric'] == row['callback']
              and (not row.get('url') or row['url'] == row['tab'].get('url')) for row in tabs),
              windows=windows, count=len(tabs))
        return tabs

    def by_url(rows, url):
        return next(row['tab'] for row in rows if row.get('url') == url)

    def wait_url(url):
        deadline = time.monotonic() + 20
        events = []
        while time.monotonic() < deadline:
            events.extend(call('updates'))
            if any(event[2] == url and event[3] == 'complete' for event in events):
                return events
            time.sleep(0.1)
        raise RuntimeError('No completed onUpdated for ' + url + ': ' + repr(events))

    deadline = time.monotonic() + 20
    while js('location.href === ' + json.dumps(urls['driver']) + ' && document.readyState === "complete"') != 'true':
        if time.monotonic() >= deadline:
            raise RuntimeError('Driver page did not finish loading')
        time.sleep(0.1)
    call('updates')
    applescript('tell application "Safari" to tell window id ' + driver
               + ' to make new tab at end of tabs with properties {URL:' + json.dumps(urls['a']) + '}')
    events = wait_url(urls['a'])
    applescript('tell application "Safari" to make new document with properties {URL:'
               + json.dumps(urls['b']) + '}')
    second = applescript('tell application "Safari" to get id of window 1')
    events.extend(wait_url(urls['b']))
    applescript('tell application "Safari" to tell window id ' + second
               + ' to make new tab at end of tabs with properties {URL:' + json.dumps(urls['c']) + '}')
    events.extend(wait_url(urls['c']))
    rows = mapping('allWindows.referencesAndNumericAndCallbacks')
    ids = {name: by_url(rows, urls[name])['id'] for name in ['a', 'b', 'c']}
    check('onUpdated.matchesReferences', all(any(event[0] == ids[name] and event[2] == urls[name]
          for event in events) for name in ids), ids=ids, events=events)
    call('updates')
    call('update', ids['a'], {'url': urls['navigated']})
    events = wait_url(urls['navigated'])
    rows = mapping('afterNavigation')
    check('navigation.sameID', by_url(rows, urls['navigated'])['id'] == ids['a']
          and all(event[0] == ids['a'] for event in events if event[2] == urls['navigated']), events=events)

    applescript('tell application "Safari" to activate\n'
               'tell application "Safari" to set index of window id ' + second + ' to 1\n'
               'tell application "Safari" to set current tab of window id ' + second + ' to tab 2 of window id ' + second + '\n'
               'tell application "System Events" to tell process "Safari" to click menu item "Move Tab to New Window" of menu "Window" of menu bar 1')
    moved = applescript('tell application "Safari" to get id of window 1')
    rows = mapping('afterMoveTabToNewWindow')
    check('move.sameID', moved != second and by_url(rows, urls['c'])['id'] == ids['c'], moved=moved, original=second)

    call('hideIds', [ids['a']])
    windows = call('mapping')
    hidden = [(window, row) for window in windows for row in window['tabs'] if row['tab']['id'] == ids['a']]
    check('hidden.referenceInInvisibleWindow', len(hidden) == 1 and not hidden[0][0]['visible']
          and hidden[0][1]['tab']['hidden'] and hidden[0][1]['tab'] == hidden[0][1]['numeric']
          == hidden[0][1]['callback'], windows=windows)
    mapping('allWindows.includingHidden')
    call('showIds', [ids['a']])
    check('numeric.callback', call('getCallback', ids['b']) == {'tab': call('get', ids['b']),
          'returnedUndefined': True})
    unknown = 9007199254740991
    error = 'No tab with id: ' + str(unknown) + '.'
    check('numeric.unknownPromise', request('get', unknown) == {'error': error}, reply=request('get', unknown))
    callback = call('getCallback', unknown)
    check('numeric.unknownCallback', callback == {'error': error, 'returnedUndefined': True}, reply=callback)

    for name, window, tab in [('closedTab', driver, 2), ('closedWindow', moved, 1)]:
        url = urls['navigated'] if name == 'closedTab' else urls['c']
        check(name + '.remembered', call('rememberTab', url))
        applescript('tell application "Safari" to close tab ' + str(tab) + ' of window id ' + window)
        stale = call('staleTab')
        expected = {'name': 'TypeError', 'message': 'A tab is a tab ID or a SafariBrowserTab of an open window.',
                    'synchronous': False}
        check(name + '.matchesOtherMethods', stale['get'] == expected and all(
              result.get('name') == expected['name'] and result.get('message') == expected['message']
              for result in stale.values()), results=stale)
    mapping('finalMapping')
    print('PASS', len(results), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('/tmp/tabs-get-verification'))
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=True)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8', LANG='en_US.UTF-8')
    run(output)
