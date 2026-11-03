#!/usr/bin/env python3
"""Check which of a Safari 7 extension's files web pages can use, and browser.scripting.executeScript.

Install resource-access.safariextension, scripting.safariextension and scripting-no-content.safariextension from
../AquaWebKit-Extensions in Extension Builder, with server.py running on port 8843.
"""

import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SERVER = 'http://127.0.0.1:8843'
failures = 0


def osascript(source, *arguments):
    process = subprocess.run(['osascript', '-', *arguments], input=source, capture_output=True, text=True, timeout=120)
    if process.returncode:
        raise RuntimeError(process.stderr)
    return process.stdout.rstrip('\n')


def in_new_tab(url, script, timeout=60):
    """Opens url in a tab, until the JavaScript `script` gives a value that is not the empty string."""
    return osascript('''
on run argv
    tell application "Safari"
        tell front window
            set t to make new tab with properties {URL:(item 1 of argv)}
            set current tab to t
        end tell
        set value to ""
        repeat ''' + str(timeout * 2) + ''' times
            delay 0.5
            try
                set value to do JavaScript (item 2 of argv) in t
            end try
            if value is not "" and value is not missing value then exit repeat
        end repeat
        close t
        return value
    end tell
end run
''', url, script)


def show_for_a_while(url, seconds):
    """Opens url in a tab. do JavaScript does not answer for an extension's page, which reports through the server."""
    osascript('''
on run argv
    tell application "Safari"
        tell front window
            set t to make new tab with properties {URL:(item 1 of argv)}
            set current tab to t
        end tell
        delay ''' + str(seconds) + '''
        close t
    end tell
end run
''', url)


def expect(name, actual, wanted):
    global failures
    if actual == wanted:
        print(f'ok    {name}')
    else:
        failures += 1
        print(f'FAIL  {name}\n      wanted {json.dumps(wanted)}\n      got    {json.dumps(actual)}')


def check_resource_access(path):
    print(f'--- {path}')
    embedder_policy = 'coep' in path
    results = json.loads(in_new_tab(SERVER + path, 'window.__results && window.__results.done ? JSON.stringify(window.__results) : ""'))
    expect('page ran to its end', results.get('pageError'), None)
    blocked = {'fetch': 'fail', 'asyncXHR': 'fail', 'syncXHR': 'fail', 'image': 'fail', 'imageCORS': 'fail'}
    expect('private: every read', results['privateBefore'], blocked)
    for key, wanted in {
        'privateScript': 'fail',
        'privateStyle': 'fail',
        'privateImport': 'fail',
        'privateFrame': 'blocked',
        'privateNoReadViaOpen': 'undefined',
        'declared': 'ok:declared file',
        'declaredDenied': 'fail',
        'denied': 'fail',
        'deniedImage': 'fail',
        'serverRedirectFetch': 'fail',
        'serverRedirectXHR': 'fail',
        'serverRedirectSyncXHR': 'fail',
        'serverRedirectImage': 'fail',
        'serverRedirectFrame': 'blocked',
        'baseImport': 'fail',
        'timelineAfterOwnReads': [],
        'privateAfterOwnReads': 'fail',
        'scriptRan': 'boolean',
        'exposedFetch': 'ok:window.__exposedScriptRan = true; functi',
        'exposedImage': 'pixels',
        'exposedStyle': 'rules:4',
        'exposedImport': 'ok:exposed module dep',
        'siblingStaysPrivate': 'fail',
        'deniedStillBlocked': 'fail',
        'extensionRedirect': 'pixels',
        'timelineAtEnd': [],
    }.items():
        expect(key, results.get(key), wanted)
    own = results.get('own') or {}
    expect('own: private fetch', own.get('fetchPrivate'), 'ok:basic:private file')
    expect('own: private async XHR', own.get('asyncXHRPrivate'), 'ok:private file')
    expect('own: private sync XHR', own.get('syncXHRPrivate'), 'ok:private file')
    expect('own: denied fetch', own.get('fetchDenied'), 'ok:basic:denied secret')
    expect('content script: exposed image', (results.get('exposedByContent') or {}).get('image'), 'loaded')
    expect('content script: denied image', (results.get('exposedByContent') or {}).get('deniedImage'), 'failed')
    expect('content script: frame', (results.get('exposedFrame') or {}).get('raFrame'), 'frame.html')
    for file, read in (results.get('plantedRead') or {}).items():
        expect(f'planted by the page: {file}', read, 'fail')
    expect('exposed sheet found', results.get('foundExposedSheet'), True)
    expect('exposed sheet @import readable', str(results.get('importedFetch')).startswith('ok'), True)
    expect('injected sheet @import readable', str(results.get('injectedImportedFetch')).startswith('ok'), True)
    for path, read in (results.get('encodedPaths') or {}).items():
        expect(f'path form: {path}', read, 'fail')
    for file, wanted in {'under-srcset-a.png': 'readable', 'under-srcset-b.png': 'readable', 'under-upper.png': 'readable', 'under-space.png': 'readable', 'under-css.txt': 'readable', 'under-style.txt': 'readable', 'r3-data.txt': 'blocked', 'under-innerhtml-style.txt': 'readable', 'under-template.png': 'readable', 'under-sheet-var.png': 'readable', 'under-sheet-custom.png': 'readable'}.items():
        expect(f'content script wrote: {file}', (results.get('underExposure') or {}).get(file), wanted)
    expect('content script: frame http image', (results.get('exposedFrame') or {}).get('image'), 'loaded')
    expect('lowercase host, denied file', results.get('hostCaseDenied'), 'fail')
    expect('sync XHR redirected to a denied file', results.get('syncRedirectDenied'), 'fail')
    expect('async XHR redirected to a denied file', results.get('asyncRedirectDenied'), 'fail')
    expect("sync XHR redirected to another extension's file", results.get('syncCrossRedirect'), 'fail')
    # NetworkResourceLoader::continueWillSendRequest refuses a server's redirect to any scheme but HTTP(S).
    expect('server redirect to an exposed image', results.get('serverRedirectExposedImage'), 'fail')
    expect('webRequest redirect of a frame to its file', results.get('redirectedFrame'), 'redirected-frame.html 77px')
    expect('verdict redirect of a frame to http', results.get('frameToHTTP'), 'timeout' if embedder_policy else 'http://127.0.0.1:8843/ra-frame-target.html http://127.0.0.1:8843')
    expect('verdict redirect of a frame to http with a policy', results.get('frameToHTTPWithPolicy'), 'http://127.0.0.1:8843/ra-frame-target-coep.html http://127.0.0.1:8843')
    # DocumentLoader::willSendRequest refuses a document load's redirect to data:.
    expect('verdict redirect of a frame to data:', results.get('frameToData'), 'timeout')
    # The server's own redirect carries no embedder policy, which upstream refuses under a parent that has one.
    expect('frame a server then a verdict redirected', results.get('frameAfterServerRedirect'), 'timeout' if embedder_policy else 'redirected-frame.html 77px')
    expect('rule redirect of a frame to http', results.get('dnrControlFrame'), 'timeout' if embedder_policy else 'http://127.0.0.1:8843/ra-frame-target.html?rule http://127.0.0.1:8843')
    expect('rule extensionPath redirect of a frame', results.get('dnrControlPathFrame'), 'redirected-frame.html 77px')
    expect("rules on a frame's subresources", results.get('frameSubresources'), 'redirected by-rule http://127.0.0.1:8843')
    expect('onHeadersReceived verdict redirect of a frame', results.get('frameHeaderVerdict'), 'redirected-frame.html 77px')
    expect('sync XHR redirected to its own private file', results.get('syncOwnPrivate'), 'ok:own private read')
    expect('other extension root known', results.get('otherRootKnown'), True)
    expect('cross-extension rules accepted', results.get('crossRules'), 'ok')
    for name in ['dnrRegexDeniedAsync', 'dnrRegexDeniedSync', 'dnrTransformDeniedAsync', 'dnrTransformDeniedSync', 'dnrRegexCrossAsync', 'dnrRegexCrossSync', 'dnrTransformCrossAsync', 'dnrTransformCrossSync', 'dnrCaptureCrossAsync', 'dnrCaptureOwnDenied']:
        expect(name, results.get(name), 'fail')
    for name in ['dnrRegexDeniedFrame', 'dnrTransformDeniedFrame', 'dnrRegexCrossFrame', 'dnrTransformCrossFrame', 'dnrCaptureCrossFrame']:
        expect(name, results.get(name), 'timeout')
    # A frame the rule did not redirect would also time out, on the server's 404.
    log = json.load(urllib.request.urlopen(SERVER + '/log'))
    expect('frame rules took effect', [entry['path'] for entry in log if entry.get('path', '').startswith(('/ra-dnr-regex-', '/ra-dnr-transform-', '/ra-dnr-capture', '/ra-dnr-control'))], [])
    expect('async XHR, rule redirect to a denied file', results.get('dnrDeniedAsync'), 'fail')
    expect('sync XHR, rule redirect to a denied file', results.get('dnrDeniedSync'), 'fail')
    expect('* in a rule path is not a wildcard', results.get('dnrStarWildcard'), 'fail')
    expect('a removed rule leaves its file closed', results.get('dnrStale'), 'fail')
    expect('static rule extensionPath image', results.get('dnrStatic'), 'pixels')
    expect('dynamic rule extensionPath image', results.get('dnrDynamic'), 'pixels')
    expect("another extension's redirect", results.get('crossRedirect'), 'fail')
    expect("another extension's redirect leaves the file private", results.get('crossRedirectRead'), 'fail')
    expect('redirect with a * host', results.get('starHostRead'), 'fail')
    expect('* host leaves the file private', results.get('starHostAfter'), 'fail')
    expect('injected style sheet image loaded', 'injected.png' in (results.get('loaded') or []), True)
    expect('exposed style sheet image loaded', 'sheet-image.png' in (results.get('loaded') or []), True)
    return results['root']


def check_scripting():
    print('--- scripting')
    report = json.loads(in_new_tab(SERVER + '/scripting-csp', '''
        (function () {
            var root = document.documentElement;
            if (!window.__started && document.readyState === "complete") {
                window.__started = true;
                setTimeout(function () { window.dispatchEvent(new Event("scripting-run")); }, 500);
            }
            return root.getAttribute("data-report") || "";
        })()'''))
    results = lambda value: [entry['result'] for entry in value] if isinstance(value, list) else value
    for key, wanted in {
        'isolatedFunc': [[1, {'two': 2}, 'undefined', 'object']],
        'protoArg': [[True, ['__proto__']]],
        'mainFunc': ['page-mark'],
        'mainHasNoAPI': [['undefined', 'none']],
        'mainAsync': ['async-page-mark'],
        'mainRejected': [None],
        'mainThrows': [None],
        'mainEvalBlocked': ['EvalError'],
        'mainHostileThen': ['resolved-by-page'],
        'mainHostileThenLeak': [True],
        'pageThenThrowingGetter': [None],
        'pageThenRestored1': ['restored'],
        'pageThenThrowingFunction': [None],
        'pageThenRestored2': ['restored'],
        'afterPageThen': ['still-working'],
        'mainHostileGetters': [{'plain': 1, 'thrower': None, 'leak': 'getter', 'proxy': {}}],
        'files': ['file-two:undefined:object'],
        'filesThrowing': [None],
        'filesBothThrow': [None],
        'fileErrorEvents': [2],
        'filesRejectHostile': [None],
        'afterRejectHostile': ['still-working'],
        'filesMain': ['file-two:string:undefined'],
        'filesHostile': ['resolved-by-page'],
        'filesHostileLeak': [True],
        'byFrameId': ['/scripting-frame.html'],
        'byDocumentId': ['/scripting-frame.html'],
    }.items():
        expect(key, results(report.get(key)), wanted)
    frames = report.get('allFrames')
    expect('allFrames paths', results(frames), ['/scripting-csp', '/scripting-frame.html'])
    if isinstance(frames, list):
        expect('allFrames main frameId', frames[0]['frameId'], 0)
        expect('allFrames fields', sorted(frames[0].keys()), ['documentId', 'frameId', 'result'])
    expect('subIsNotMain', report.get('subIsNotMain'), True)
    for key, wanted in {
        'errBoth': "error:Exactly one of 'func' and 'files' must be specified.",
        'errNeither': "error:Exactly one of 'func' and 'files' must be specified.",
        'errArgsFiles': "error:'args' may not be used with file injections.",
        'errWorld': 'error:Error in invocation of scripting.executeScript: Value must be one of ISOLATED, MAIN.',
        'errAllAndFrames': "error:Cannot specify both 'allFrames' and 'frameIds'.",
        'errFramesAndDocs': "error:Cannot specify both 'frameIds' and 'documentIds'.",
        'errNoFrame': 'error:No frame with id 987654321 in tab with id ',
        'errNoDocument': 'error:No document with id nope in tab with id ',
        'errNoTab': 'error:No tab with id: 987654321.',
        'errFile': "error:Could not load file: 'missing.js'.",
        'errNotFunc': "error:Error in invocation of scripting.executeScript: 'func' must be a function.",
    }.items():
        actual = report.get(key)
        if key in ('errNoFrame', 'errNoDocument') and isinstance(actual, str):
            actual = actual[:len(wanted)]
        expect(key, actual, wanted)


def server_reports(kind):
    with urllib.request.urlopen(SERVER + '/log') as response:
        entries = json.load(response)
    found = []
    for entry in entries:
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(entry.get('path', '')).query)
        if query.get('kind') == [kind]:
            found.append(json.loads(query['state'][0]))
    return found


def check_timing():
    print('--- injectImmediately')
    urllib.request.urlopen(SERVER + '/reset').read()
    in_new_tab(SERVER + '/scripting-slow', 'window.slowScriptDone ? "done" : ""')
    time.sleep(2)
    immediate = server_reports('immediate')
    idle = server_reports('idle')
    expect('injected immediately ran before load finished', bool(immediate) and immediate[-1][0]['result'], 'loading')
    expect('default waited for the document', bool(idle) and idle[-1][0]['result'] in ('interactive', 'complete'), True)


def check_no_content_scripts():
    print('--- no content scripts')
    urllib.request.urlopen(SERVER + '/reset').read()
    # The extension scripts the tab from tabs.onUpdated, so the tab stays open while it does.
    in_new_tab(SERVER + '/scripting-no-content', '''
        (function () {
            window.__opened = window.__opened || Date.now();
            return document.readyState === "complete" && Date.now() - window.__opened > 3000 ? "done" : "";
        })()''')
    reports = server_reports('no-content')
    report = reports[-1] if reports else {}
    results = lambda value: [entry['result'] for entry in value] if isinstance(value, list) else value
    expect('isolated world has the API, not the page', results(report.get('isolated')), [['undefined', 'object', 'function']])
    expect('isolated world persists', [results(report.get('isolatedPersists')), results(report.get('isolatedPersists2'))], [[1], [2]])
    expect('main world', results(report.get('main')), [['page-mark', 'undefined']])
    expect('file', results(report.get('file')), ['file-one'])


def check_import_map():
    print('--- import map')
    results = json.loads(in_new_tab(SERVER + '/resource-access-importmap.html', 'window.__results && window.__results.done ? JSON.stringify(window.__results) : ""'))
    expect("a page's import map exposes nothing", results['secretFetch'], 'failed')


def check_quirks_mode():
    print('--- quirks mode')
    results = json.loads(in_new_tab(SERVER + '/resource-access-quirks.html', 'window.__results && window.__results.done ? JSON.stringify(window.__results) : ""'))
    expect('page is in quirks mode', results.get('quirks'), 'BackCompat')
    expect('an exposed script parsed as a style sheet exposes nothing', results.get('exposedJSAsSheet'), 'failed')
    expect('a declared text file parsed as a style sheet exposes nothing', results.get('declaredTextAsSheet'), 'failed')


def check_other_extension(target):
    print("--- another extension's page")
    urllib.request.urlopen(SERVER + '/reset').read()
    show_for_a_while(SERVER + '/scripting-csp?cross=' + urllib.parse.quote(target, safe=''), 5)
    reports = server_reports('cross')
    results = reports[-1] if reports else {}
    expect('private image', results.get('privateImage'), 'failed')
    expect('denied image', results.get('deniedImage'), 'failed')
    expect('private fetch', results.get('privateFetch'), 'failed')
    expect('declared fetch', results.get('declaredFetch'), 'read')


root = check_resource_access('/resource-access.html')
if len(sys.argv) > 1 and sys.argv[1] == '--other-extension-only':
    check_other_extension(root)
    print(f'{failures} failure(s)')
    sys.exit(1 if failures else 0)
check_resource_access('/resource-access-coep')
check_import_map()
check_quirks_mode()
print('--- main frame rules')
urllib.request.urlopen(SERVER + '/reset').read()
expect('main frame rule to http', in_new_tab(SERVER + '/ra-dnr-main-control.html', 'document.readyState === "complete" ? location.href : ""'), SERVER + '/ra-frame-target.html?mainrule')
for path in ['/ra-dnr-main-denied.html', '/ra-dnr-main-cross.html']:
    # A page refused by a rule or an extension page answers no script here, so the file reports for itself.
    osascript('''
on run argv
    tell application "Safari"
        tell front window
            set t to make new tab with properties {URL:(item 1 of argv)}
        end tell
        delay 3
        close t
    end tell
end run
''', SERVER + path)
log = json.load(urllib.request.urlopen(SERVER + '/log'))
expect('main frame rules load no denied or other extension file', [entry['path'] for entry in log if 'raLeak' in entry.get('path', '')], [])
expect('main frame rules took effect', [entry['path'] for entry in log if entry.get('path', '').startswith(('/ra-dnr-main-denied', '/ra-dnr-main-cross'))], [])
print('--- main frame a server then a verdict redirected')
expect('main frame URL', in_new_tab(SERVER + '/to-url?to=' + urllib.parse.quote(SERVER + '/ra-main-after-server.html'), 'document.readyState === "complete" ? location.href : ""'), SERVER + '/ra-frame-target.html?main')
check_other_extension(root)
check_scripting()
check_timing()
check_no_content_scripts()
print(f'{failures} failure(s)')
sys.exit(1 if failures else 0)
