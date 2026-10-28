#!/usr/bin/env python3
"""Exercise aqua.input.performEditingAction through a legacy extension's global page.

Run server.py and install the sibling AquaWebKit-Extensions workspace's
inspector.safariextension in Safari's Extension Builder first. This opens a window
with two local tabs and leaves it open for inspection. State comes from Safari's
`do JavaScript`; clipboard bytes come from `pbpaste`.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


BASE_URL = 'http://localhost:8843/'


def applescript(source):
    return subprocess.check_output(['osascript', '-e', source], text=True).strip()


def javascript(source, tab=1):
    return applescript('tell application "Safari" to do JavaScript '
                       + json.dumps(source) + ' in tab ' + str(tab) + ' of window 1')


def value(expression, tab=1):
    return json.loads(javascript('JSON.stringify((' + expression + '))', tab))


def request(method, argument, tab=1):
    javascript('requestInput(' + json.dumps(method) + ',' + json.dumps(argument) + ')', tab)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        answers = value('__answers', tab)
        if 'inputSelf' in answers:
            return answers['inputSelf']
        time.sleep(0.05)
    raise RuntimeError('No extension answer: ' + repr((method, argument, tab)))


def state(tab):
    return value('state()', tab)


def pasteboard():
    return subprocess.check_output(['pbpaste'], text=True)


def set_pasteboard(text):
    subprocess.run(['pbcopy'], input=text, text=True, check=True)


def wait_for_page(tab):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if javascript('typeof state', tab) == 'function':
            return
        time.sleep(0.1)
    raise RuntimeError('Test page did not load in tab ' + str(tab))


def run(output):
    results = []

    def check(name, ok, **data):
        row = dict(name=name, ok=bool(ok), **data)
        results.append(row)
        print(json.dumps(row), flush=True)
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        if not ok:
            raise AssertionError(name)

    def action(selector, tab):
        reply = request('performEditingAction', selector, tab)
        check(str(tab) + '.' + selector, reply == {'done': True}, reply=reply)

    def screenshot(name):
        window_id = applescript('tell application "Safari" to get id of window 1')
        subprocess.check_call(['/usr/sbin/screencapture', '-x', '-l' + window_id,
                               str(output / (name + '.png'))])

    applescript('tell application "Safari" to make new document with properties '
                '{URL:"' + BASE_URL + 'editing-actions.html?shown"}')
    applescript('tell application "Safari" to tell window 1 to make new tab at end of tabs '
                'with properties {URL:"' + BASE_URL + 'editing-actions.html?background"}')

    for tab, place in [(1, 'shown'), (2, 'background')]:
        wait_for_page(tab)
        applescript('tell application "Safari" to set current tab of window 1 to tab 1 of window 1')
        javascript("field.value=''; field.focus(); __events=[]; 'ready'", tab)
        for event_type in ['keyDown', 'keyUp']:
            reply = request('dispatchKeyEvent', dict(type=event_type, keyCode=7, characters='x'), tab)
            check(place + '.typing.' + event_type, reply == {'done': True}, reply=reply)
        check(place + '.typed', state(tab)['field'] == 'x', state=state(tab))
        if tab == 1:
            action('undo:', tab)
            check(place + '.undo', state(tab)['field'] == '', state=state(tab))
            action('redo:', tab)
            check(place + '.redo', state(tab)['field'] == 'x', state=state(tab))
        else:
            shown_field = state(1)['field']
            for selector in ['undo:', 'redo:']:
                reply = request('performEditingAction', selector, tab)
                check(place + '.' + selector + '.noTarget',
                      reply == {'error': 'No target for editing action: ' + selector}, reply=reply)
            check(place + '.undoDoesNotReachShownTab', state(1)['field'] == shown_field
                  and state(tab)['field'] == 'x', fields=[state(1)['field'], state(tab)['field']])

        javascript("field.value='Field selection'; field.focus(); field.setSelectionRange(3,3); __events=[]; 'ready'", tab)
        action('selectAll:', tab)
        check(place + '.selectField', state(tab)['range'] == [0, 15], state=state(tab))
        if tab == 1:
            screenshot('shown-field')
        action('copy:', tab)
        check(place + '.copy', pasteboard() == 'Field selection', pasteboard=pasteboard(), state=state(tab))
        action('cut:', tab)
        check(place + '.cut', state(tab)['field'] == '' and pasteboard() == 'Field selection',
              pasteboard=pasteboard(), state=state(tab))

        text = 'Paste ' + place + ' café ✓'
        set_pasteboard(text)
        action('paste:', tab)
        snapshot = state(tab)
        events = [event for event in snapshot['events'] if event['type'] == 'paste']
        check(place + '.paste', snapshot['field'] == text and events[-1]['text'] == text
              and events[-1]['trusted'], state=snapshot)

        javascript('__customClipboard=true; field.select(); "ready"', tab)
        action('copy:', tab)
        check(place + '.DOMCopy', pasteboard() == 'DOM copy payload', pasteboard=pasteboard())
        action('cut:', tab)
        check(place + '.DOMCut', pasteboard() == 'DOM cut payload', pasteboard=pasteboard())

        javascript('__customClipboard=false; field.blur(); getSelection().removeAllRanges(); "ready"', tab)
        action('selectAll:', tab)
        check(place + '.selectBody', 'copper, silver, gold.' in state(tab)['selection'], state=state(tab))
        if tab == 1:
            screenshot('shown-body')
        action('copy:', tab)
        check(place + '.copyBody', 'copper, silver, gold.' in pasteboard(), pasteboard=pasteboard())

        javascript('field.blur(); getSelection().removeAllRanges(); "ready"', tab)
        for selector in ['copy:', 'cut:', 'paste:']:
            reply = request('performEditingAction', selector, tab)
            check(place + '.disabled.' + selector,
                  reply == {'error': 'Editing action is disabled: ' + selector}, reply=reply)
        for selector in ['copy', 'noSuchAction:', 'close:', 'insertText:', 'copy:\u0000garbage']:
            reply = request('performEditingAction', selector, tab)
            check(place + '.unsupported.' + repr(selector),
                  reply == {'error': 'Unsupported editing action: ' + selector}, reply=reply)
        reply = request('performEditingAction', 7, tab)
        check(place + '.badType', reply == {'error': 'An editing action is a selector name string'}, reply=reply)

    for tab in [1, 2]:
        javascript('field.value="mixed words"; field.focus(); "ready"', tab)
        action('selectAll:', tab)
        for selector, expected in [('uppercaseWord:', 'MIXED WORDS'),
                                   ('lowercaseWord:', 'mixed words'),
                                   ('capitalizeWord:', 'Mixed Words')]:
            action(selector, tab)
            check(str(tab) + '.' + selector + '.text', state(tab)['field'] == expected, state=state(tab))
        action('selectAll:', tab)
        set_pasteboard('Plain text paste')
        action('pasteAsPlainText:', tab)
        check(str(tab) + '.pasteAsPlainText.text', state(tab)['field'] == 'Plain text paste', state=state(tab))
        action('selectAll:', tab)
        set_pasteboard('Delete preserves the pasteboard')
        action('delete:', tab)
        check(str(tab) + '.delete.text', state(tab)['field'] == ''
              and pasteboard() == 'Delete preserves the pasteboard', state=state(tab), pasteboard=pasteboard())

    # The window remains inactive throughout both pastes.
    applescript('tell application "Terminal" to activate')
    for tab in [1, 2]:
        javascript('field.value=""; field.focus(); __events=[]; "ready"', tab)
        text = 'Inactive window paste ' + str(tab)
        set_pasteboard(text)
        action('paste:', tab)
        snapshot = state(tab)
        event = next(event for event in snapshot['events'] if event['type'] == 'paste')
        check('inactive.paste.' + str(tab), snapshot['field'] == text and not snapshot['hasFocus']
              and event['text'] == text and event['trusted'], state=snapshot)
    frontmost = applescript('tell application "System Events" to get name of first application process whose frontmost is true')
    check('inactive.focusPreserved', frontmost == 'Terminal', frontmost=frontmost)
    applescript('tell application "Safari" to activate')
    applescript('tell application "Safari" to set current tab of window 1 to tab 2 of window 1')
    screenshot('background-paste')

    # The old window clears this view's edit commands before the tab is detached.
    applescript('tell application "Safari" to set current tab of window 1 to tab 1 of window 1')
    javascript('field.value=""; field.focus(); "ready"', 1)
    for event_type in ['keyDown', 'keyUp']:
        request('dispatchKeyEvent', dict(type=event_type, keyCode=7, characters='x'), 1)
    check('windowMove.typed', state(1)['field'] == 'x', state=state(1))
    applescript('tell application "Safari" to set current tab of window 1 to tab 2 of window 1')
    reply = request('performEditingAction', 'undo:', 1)
    check('windowMove.detached', reply == {'error': 'No target for editing action: undo:'}, reply=reply)
    for tab in [2, 1]:
        applescript('tell application "Safari" to set current tab of window 1 to tab '
                    + str(tab) + ' of window 1')
        for selector in ['undo:', 'redo:']:
            reply = request('performEditingAction', selector, tab)
            check('windowMove.cleared.' + str(tab) + '.' + selector,
                  reply == {'error': 'Editing action is disabled: ' + selector}, reply=reply)
    check('windowMove.textPreserved', state(1)['field'] == 'x', state=state(1))
    screenshot('window-move-clears-undo')
    print('PASS', len(results))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('/tmp/aqua-editing-actions'))
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=True)
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8', LANG='en_US.UTF-8')
    urllib.request.urlopen(BASE_URL + 'clipboard-lock', timeout=30).close()
    try:
        run(output)
    finally:
        urllib.request.urlopen(BASE_URL + 'clipboard-unlock', timeout=30).close()


if __name__ == '__main__':
    main()
