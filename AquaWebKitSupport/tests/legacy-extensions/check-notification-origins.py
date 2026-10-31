#!/usr/bin/python
"""Check the C API origin construction Safari uses for extension grants."""
from __future__ import print_function
import ctypes

webkit = ctypes.CDLL('/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit')
pointer = ctypes.c_void_p
for name, arguments, result in [
    ('WKStringCreateWithUTF8CString', [ctypes.c_char_p], pointer),
    ('WKSecurityOriginCreate', [pointer, pointer, ctypes.c_int], pointer),
    ('WKSecurityOriginCreateFromString', [pointer], pointer),
    ('WKSecurityOriginCopyToString', [pointer], pointer),
    ('WKStringGetUTF8CString', [pointer, ctypes.c_char_p, ctypes.c_size_t], ctypes.c_size_t),
    ('WKRelease', [pointer], None),
]:
    function = getattr(webkit, name)
    function.argtypes = arguments
    function.restype = result


def origin_string(protocol, host, port):
    scheme = webkit.WKStringCreateWithUTF8CString(protocol.encode('utf-8'))
    hostname = webkit.WKStringCreateWithUTF8CString(host.encode('utf-8'))
    origin = webkit.WKSecurityOriginCreate(scheme, hostname, port)
    result = stringify(origin)
    for value in (scheme, hostname, origin):
        webkit.WKRelease(value)
    return result


def stringify(origin):
    text = webkit.WKSecurityOriginCopyToString(origin)
    buffer = ctypes.create_string_buffer(1024)
    webkit.WKStringGetUTF8CString(text, buffer, len(buffer))
    webkit.WKRelease(text)
    return buffer.value.decode('utf-8')


cases = [
    ('safari-extension', 'org.webkit.extension-notifications-test-WDAOQFIKHZ', 0,
     'safari-extension://org.webkit.extension-notifications-test-wdaoqfikhz'),
    ('HTTPS', 'LOCALHOST', 0, 'https://localhost'),
    ('https', 'LOCALHOST', 443, 'https://localhost'),
    ('https', 'LOCALHOST', 8846, 'https://localhost:8846'),
    ('safari-extension', 'other-WDAOQFIKHZ', 0, 'safari-extension://other-wdaoqfikhz'),
    ('x-unregistered', 'Host', 0, 'x-unregistered://host'),
]
failed = False
for protocol, host, port, expected in cases:
    actual = origin_string(protocol, host, port)
    matched = actual == expected
    print(('PASS' if matched else 'FAIL'), repr((protocol, host, port)), repr(actual), 'expected', repr(expected))
    failed = failed or not matched
raise SystemExit(1 if failed else 0)
