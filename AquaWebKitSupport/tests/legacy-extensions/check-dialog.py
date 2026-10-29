#!/usr/bin/env python3
"""Exercise aqua.dialog through the sibling dialog*.safariextension global pages.

Run server.py and install the four fixtures in Safari's Extension Builder first.
The page state is read with do JavaScript, and modal-time reports come from /log.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse
import urllib.request

BASE = 'http://localhost:8843/'


def applescript(source):
    return subprocess.check_output(['osascript', '-e', source], text=True, timeout=15).strip()


def wait_for(function, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = function()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timed out: ' + repr(function))


class Driver:
    def __init__(self, output):
        self.output = output
        self.results = []
        applescript('tell application "Safari" to make new document with properties '
                    '{URL:"' + BASE + 'dialog.html"}')
        self.window = int(applescript('tell application "Safari" to get id of window 1'))
        wait_for(lambda: self.js('typeof dialogCommand') == 'function')

    def js(self, source, tab=1):
        return applescript('tell application "Safari" to do JavaScript ' + json.dumps(source)
                           + ' in tab ' + str(tab) + ' of window id ' + str(self.window))

    def value(self, source, tab=1):
        return json.loads(self.js('JSON.stringify((' + source + '))', tab))

    def request(self, op, fixture='dialog', tab=1, **arguments):
        identifier = int(float(self.js('dialogCommand(' + json.dumps(dict(op=op, fixture=fixture, **arguments)) + ')', tab)))
        return wait_for(lambda: self.value('dialogReplies[' + str(identifier) + '] || null', tab))

    def check(self, name, ok, **data):
        result = dict(name=name, ok=bool(ok), **data)
        self.results.append(result)
        print(json.dumps(result), flush=True)
        (self.output / 'results.json').write_text(json.dumps(self.results, indent=2))
        if not ok:
            raise AssertionError(name)

    def screenshot(self, name):
        applescript('tell application "Safari" to activate')
        subprocess.check_call(['/usr/sbin/screencapture', '-x', str(self.output / (name + '.png'))])

    def reports(self):
        with urllib.request.urlopen(BASE + 'log', timeout=5) as response:
            logs = json.load(response)
        result = []
        for row in logs:
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(row.get('path', '')).query)
            if 'dialog' in query:
                result.append(json.loads(query['dialog'][0]))
        return result

    def dialogs(self):
        return applescript('tell application "System Events" to tell process "Safari" '
                           'to get name of every window whose subrole is "AXDialog"')

    def user_accept(self):
        applescript('tell application "System Events" to tell process "Safari" to '
                    'click button "OK" of first window whose subrole is "AXDialog"')
        if not self.dialogs():
            return 'AXPress'
        applescript('tell application "System Events" to tell process "Safari"\n'
                    'set frontmost to true\nkey code 36\nend tell')
        wait_for(lambda: not self.dialogs())
        return 'Return'

    def clear(self):
        urllib.request.urlopen(BASE + 'reset', timeout=5).close()
        for fixture in ['dialog', 'dialog-second', 'dialog-limited', 'dialog-insecure']:
            self.request('clear', fixture=fixture)

    def no_pending(self, name, tab=1):
        result = self.request('answer', answer={'accept': True}, tab=tab)
        self.check(name + '.noPending', result == {'error': 'The tab has no open JavaScript dialog.'}, result=result)
        self.check(name + '.panelGone', not self.dialogs())

    def dialog_case(self, name, kind, answer, expected, tab=1, twice=False):
        self.clear()
        target = self.request('arm', policy={'answer': answer, 'delay': 1800, 'twice': twice}, tab=tab)['tabId']
        message = name + ': \"quoted\"\nUnicode café 日本語'
        self.js('openDialog(' + json.dumps(kind) + ',' + json.dumps(message) + ',"seed")', tab)
        opened = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'open' and row['fixture'] == 'dialog'])
        self.screenshot(name + '-open')
        expected_dialog = {'type': kind, 'message': message}
        if kind == 'prompt':
            expected_dialog['defaultText'] = 'seed'
        self.check(name + '.event', opened[0]['tabId'] == target and opened[0]['dialog'] == expected_dialog, event=opened[0])
        answers = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog'])
        self.check(name + '.answered', any(row.get('ok') for row in answers), answers=answers)
        state = self.value('dialogState', tab)
        self.check(name + '.result', state['returned'] and state['value'] == expected, state=state)
        if twice:
            answers = [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog']
            self.check(name + '.secondRejected', len(answers) == 2 and sum(bool(row.get('ok')) for row in answers) == 1, answers=answers)
        self.check(name + '.accessEventFiltered', not any(row['fixture'] in ['dialog-limited', 'dialog-insecure'] and row['phase'] == 'open' for row in self.reports()))
        self.no_pending(name, tab)
        self.screenshot(name + '-returned')

    def run(self):
        self.no_pending('initial')
        for fixture in ['dialog-limited', 'dialog-insecure']:
            result = self.request('answer', fixture=fixture, answer={'accept': True})
            self.check(fixture + '.access', result == {'error': 'Missing host permission for the tab'}, result=result)
        for name, kind, answer, expected in [
            ('alert', 'alert', {'accept': True}, 'undefined'),
            ('alert-dismiss', 'alert', {'accept': False}, 'undefined'),
            ('confirm-accept', 'confirm', {'accept': True}, True),
            ('confirm-dismiss', 'confirm', {'accept': False}, False),
            ('prompt-text', 'prompt', {'accept': True, 'text': 'answer café 日本語'}, 'answer café 日本語'),
            ('prompt-default', 'prompt', {'accept': True}, 'seed'),
            ('prompt-empty', 'prompt', {'accept': True, 'text': ''}, ''),
            ('prompt-dismiss', 'prompt', {'accept': False, 'text': 'ignored'}, ''),
        ]:
            self.dialog_case(name, kind, answer, expected)

        self.clear()
        self.request('arm', policy={'answer': {'accept': True}, 'delay': 4000})
        self.js('openDialog("prompt", "Preserve user-edited text", "seed")')
        wait_for(self.dialogs)
        applescript('tell application "System Events" to tell process "Safari" to '
                    'set value of text field 1 of (first window whose subrole is "AXDialog") to "user edited"')
        self.screenshot('prompt-current-open')
        wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog'])
        state = self.value('dialogState')
        self.check('prompt-current.result', state['returned'] and state['value'] == 'user edited', state=state)
        self.no_pending('prompt-current')
        self.dialog_case('twice', 'confirm', {'accept': True}, True, twice=True)

        applescript('tell application "Safari" to make new tab at end of tabs of window id '
                    + str(self.window) + ' with properties {URL:"' + BASE + 'dialog.html?background"}')
        wait_for(lambda: self.js('typeof dialogCommand', 2) == 'function')
        applescript('tell application "Safari" to set current tab of window id ' + str(self.window)
                    + ' to tab 1 of window id ' + str(self.window))
        self.dialog_case('background', 'confirm', {'accept': False}, False, tab=2)

        self.clear()
        other_tab = self.request('status', tab=2)['tabId']
        self.request('arm', policy={'answer': {'accept': True}, 'delay': 300, 'probeTab': other_tab})
        self.js('openDialog("confirm", "IPC while modal")')
        ipc = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'ipc'])
        self.check('modal.ipcRoundTrip', ipc[0]['result'] == ['ran'], result=ipc)
        wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog'])
        self.no_pending('modal-ipc')

        self.clear()
        self.request('arm', policy={'answer': {'accept': False}, 'delay': 4000})
        self.js('openDialog("confirm", "The user answers first")')
        wait_for(self.dialogs)
        self.screenshot('user-first-open')
        activation = self.user_accept()
        wait_for(lambda: not self.dialogs())
        answers = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog'])
        self.check('user-first.rejected', answers[0].get('error') == 'The tab has no open JavaScript dialog.', answers=answers)
        self.check('user-first.result', self.value('dialogState.value') is True, activation=activation)
        self.no_pending('user-first')
        self.screenshot('user-first-returned')

        self.clear()
        for fixture in ['dialog', 'dialog-second']:
            self.request('arm', fixture=fixture, policy={'answer': {'accept': True}, 'delay': 500})
        self.js('openDialog("confirm", "Two extensions")')
        wait_for(lambda: len([row for row in self.reports() if row.get('phase') == 'answer']) >= 2)
        answers = [row for row in self.reports() if row.get('phase') == 'answer']
        self.check('two-extensions.oneAnswer', len(answers) == 2 and sum(bool(row.get('ok')) for row in answers) == 1, answers=answers)
        self.no_pending('two-extensions')

        for accept in [False, True]:
            name = 'beforeunload-' + ('accept' if accept else 'dismiss')
            self.clear()
            self.request('arm', policy={'answer': {'accept': accept}, 'delay': 1800})
            self.request('gesture')
            self.js('armBeforeUnload(); "armed"')
            applescript('ignoring application responses\ntell application "Safari" to set URL of tab 1 of window id '
                        + str(self.window) + ' to "' + BASE + 'dialog.html?destination"\nend ignoring')
            opened = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'open' and row['fixture'] == 'dialog'])
            self.check(name + '.event', opened[0]['dialog'] == {'type': 'beforeunload', 'message': 'page supplied beforeunload message'}, event=opened[0])
            self.screenshot(name + '-open')
            wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'answer' and row['fixture'] == 'dialog'])
            url = self.js('location.href')
            self.check(name + '.navigation', ('?destination' in url) == accept, url=url)
            self.js('window.onbeforeunload=null; "cleared"')
            self.no_pending(name)
            self.screenshot(name + '-returned')
        self.clear()
        applescript('tell application "System Events" to tell process "Safari" to '
                    'click menu item "Suppress Alerts" of menu "Debug" of menu bar 1')
        try:
            for kind in ['alert', 'confirm', 'prompt']:
                self.js('openDialog(' + json.dumps(kind) + ', "Suppressed by Safari")')
                wait_for(lambda: self.value('dialogState.returned'))
                self.check('suppressed.' + kind + '.noEvent', not any(row['phase'] == 'open' for row in self.reports()))
                self.no_pending('suppressed.' + kind)
        finally:
            applescript('tell application "System Events" to tell process "Safari" to '
                        'click menu item "Suppress Alerts" of menu "Debug" of menu bar 1')

        self.clear()
        target = self.request('closeOnOpen', tab=2)['tabId']
        self.js('openDialog("confirm", "Tab closes while open")', 2)
        answers = wait_for(lambda: [row for row in self.reports() if row.get('phase') == 'closed-answer'])
        self.check('closed-tab.rejected', answers[0].get('error') == 'No tab with this id.', answers=answers)
        self.check('closed-tab.panelStays', bool(self.dialogs()))
        self.screenshot('closed-tab')
        self.user_accept()
        wait_for(lambda: not self.dialogs())
        self.check('closed-tab.closed', int(applescript('tell application "Safari" to count tabs of window id ' + str(self.window))) == 1)

        local_file = (Path(__file__).parent / 'pages' / 'dialog.html').resolve().as_uri()
        applescript('tell application "Safari" to make new tab at end of tabs of window id '
                    + str(self.window) + ' with properties {URL:' + json.dumps(local_file) + '}')
        wait_for(lambda: self.js('typeof openDialog', 2) == 'function')
        applescript('tell application "Safari" to set index of window id ' + str(self.window) + ' to 1')
        target = self.request('tabAt', index=1)
        self.clear()
        self.js('openDialog("alert", "File URL access boundary")', 2)
        wait_for(self.dialogs)
        self.screenshot('file-access-open')
        self.user_accept()
        wait_for(lambda: not self.dialogs())
        result = self.request('answer', tabId=target, answer={'accept': True})
        self.check('file-access.rejected', result.get('error', '').startswith('Cannot access the page of the tab'), result=result)
        self.check('file-access.noEvent', not any(row['phase'] == 'open' for row in self.reports()))
        applescript('tell application "Safari" to close tab 2 of window id ' + str(self.window))
        print('PASS', len(self.results), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('/tmp/aqua-dialog-results'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8', LANG='en_US.UTF-8')
    Driver(args.output).run()


if __name__ == '__main__':
    main()
