#!/usr/bin/python
# Expected values come from AppKit 1561.60.100's native filter methods.
import ctypes as C
import sys
import AppKit
import objc

class Point(C.Structure):
    _fields_ = [('x', C.c_double), ('y', C.c_double)]

runtime = C.CDLL('/usr/lib/libobjc.A.dylib')
runtime.objc_getClass.argtypes = [C.c_char_p]
runtime.objc_getClass.restype = C.c_void_p
runtime.sel_registerName.argtypes = [C.c_char_p]
runtime.sel_registerName.restype = C.c_void_p
selector = runtime.sel_registerName
send = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_void_p)(('objc_msgSend', runtime))
filter_delta = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, Point, C.c_double,
                          C.POINTER(Point), C.POINTER(Point))(('objc_msgSend', runtime))
filter_event = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_void_p,
                          C.POINTER(Point), C.POINTER(Point))(('objc_msgSend', runtime))
set_mode = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_long)(('objc_msgSend', runtime))
reset_stale = C.CFUNCTYPE(C.c_bool, C.c_void_p, C.c_void_p, C.c_double)(('objc_msgSend', runtime))

# A typed event double supplies exact timestamps and every NSEvent phase.
class WKAxisFilterTestEvent(AppKit.NSObject):
    def type(self): return AppKit.NSScrollWheel
    type = objc.selector(type, signature='Q@:')
    def phase(self): return self.event_phase
    phase = objc.selector(phase, signature='Q@:')
    def momentumPhase(self): return self.momentum_phase
    momentumPhase = objc.selector(momentumPhase, signature='Q@:')
    def timestamp(self): return self.event_time
    timestamp = objc.selector(timestamp, signature='d@:')
    def scrollingDeltaX(self): return self.dx
    scrollingDeltaX = objc.selector(scrollingDeltaX, signature='d@:')
    def scrollingDeltaY(self): return self.dy
    scrollingDeltaY = objc.selector(scrollingDeltaY, signature='d@:')

failures = 0
checks = 0

def expect(condition, label):
    global failures, checks
    checks += 1
    if not condition:
        failures += 1
        print('FAIL ' + label)

def near(actual, expected):
    return all(abs(a - e) <= 1e-9 * max(1, abs(e)) for a, e in zip(actual, expected))

def sample(f, delta, timestamp, expected_delta, expected_velocity, label, event=None):
    d = Point(987, 654)
    v = Point(321, 123)
    if event is None:
        filter_delta(f, selector('filterInputDelta:timestamp:outputDelta:velocity:'), Point(*delta), timestamp, C.byref(d), C.byref(v))
    else:
        event.dx, event.dy = delta
        event.event_time = timestamp
        filter_event(f, selector('filterInputScrollEvent:outputDelta:velocity:'), objc.pyobjc_id(event), C.byref(d), C.byref(v))
    actual = (d.x, d.y, v.x, v.y)
    expected = expected_delta + expected_velocity
    expect(near(actual, expected), '%s: got %s expected %s' % (label, actual, expected))


def exercise(new_filter):
    f = new_filter()
    for i, (delta, velocity) in enumerate([
        ((0, -10), (0, 0)), ((0, -40), (0, -2500)),
        ((0, -40), (0, -2500)), ((0, -40), (0, -2500)),
        ((0, 0), (0, -500)), ((0, 0), (0, -100)), ((0, 0), (0, -20)),
        ((-40, 0), (-2500, -4)), ((-40, 0), (-2500, -0.8))]):
        sample(f, delta, 1 + i * .016, delta, velocity, 'L-shaped gesture %d' % i)
    f = new_filter()
    for i, (delta, velocity) in enumerate([
        ((-10, 0), (0, 0)), ((-100, 0), (-6250, 0)), ((-100, 0), (-6250, 0)),
        ((0, 120), (-1250, 6000)), ((0, 120), (-250, 7200))]):
        sample(f, delta, 1 + i * .016, delta, velocity, 'rubberband axis switch %d' % i)
    f = new_filter()
    for i, (delta, filtered, velocity) in enumerate([
        ((.25, 1), (0, 1), (0, 0)), ((1, 10), (0, 10), (0, 100)),
        ((5, 5), (0, 5), (0, 60)), ((-10, 1), (-10, 0), (-100, 12)),
        ((10, 1), (10, 0), (100, 2.4))]):
        sample(f, delta, 2 + i * .1, filtered, velocity, 'jitter/tie/reversal %d' % i)
    for mode, expected in [(0, (9, 12)), (1, (9, 0)), (2, (0, 12)), (3, (0, 12)), (4, (0, 12))]:
        f = new_filter()
        set_mode(f, selector('setPredominantAxisMode:'), mode)
        sample(f, (9, 12), 0, expected, (0, 0), 'axis mode %d' % mode)
        send(f, selector('reset'))
        sample(f, (9, 12), 1, expected, (0, 0), 'reset preserves mode %d' % mode)
    f = new_filter()
    sample(f, (0, 10), 0, (0, 10), (0, 0), 'timestamp zero')
    sample(f, (0, 10), .1, (0, 10), (0, 100), 'second sample')
    sample(f, (0, 90), .1, (0, 90), (0, 100), 'duplicate timestamp')
    sample(f, (0, 90), .05, (0, 90), (0, 100), 'decreasing timestamp')
    sample(f, (0, 5), .15, (0, 5), (0, 60), 'timestamp follows decreasing sample')
    sample(f, (0, 10), .5, (0, 10), (0, 0), 'expired sample')
    sample(f, (0, 10), .6, (0, 10), (0, 100), 'first velocity after expiry')
    expect(not reset_stale(f, selector('resetIfOutOfDate:'), .7), 'fresh timestamp preserves state')
    expect(reset_stale(f, selector('resetIfOutOfDate:'), .9), 'stale timestamp clears state')
    expect(not reset_stale(f, selector('resetIfOutOfDate:'), 1), 'reset timestamp is empty')
    sample(f, (0, 10), 1, (0, 10), (0, 0), 'first sample after explicit expiry')
    f = new_filter()
    sample(f, (10, 0), 0, (10, 0), (0, 0), 'timeout boundary seed')
    sample(f, (10, 0), .2, (10, 0), (50, 0), 'exactly 200 ms remains valid')
    filter_delta(f, selector('filterInputDelta:timestamp:outputDelta:velocity:'), Point(10, 0), .3, None, None)
    sample(f, (10, 0), .4, (10, 0), (98, 0), 'null outputs still accumulate')

    event = WKAxisFilterTestEvent.alloc().init()
    f = new_filter()
    event.event_phase, event.momentum_phase = 1, 0
    sample(f, (0, 10), 1, (0, 10), (0, 0), 'event began', event)
    event.event_phase = 4
    sample(f, (0, 10), 1.1, (0, 10), (0, 100), 'event changed', event)
    event.event_phase = 8
    sample(f, (0, 90), 1.12, (0, 0), (0, 100), 'event ended retains velocity', event)
    event.event_phase, event.momentum_phase = 0, 1
    sample(f, (10, 0), 1.15, (10, 0), (160, 20), 'momentum began', event)
    event.momentum_phase = 4
    sample(f, (10, 0), 1.2, (10, 0), (192, 4), 'momentum changed', event)
    event.momentum_phase = 8
    sample(f, (0, 0), 1.25, (0, 0), (192, 4), 'momentum ended', event)
    event.momentum_phase = 0
    sample(f, (8, 9), 10, (987, 654), (321, 123), 'phaseless event leaves outputs untouched', event)
    for phase, momentum in [(2, 0), (16, 0), (32, 0), (0, 2), (0, 16)]:
        event.event_phase, event.momentum_phase = phase, momentum
        sample(f, (8, 9), 11, (0, 0), (0, 0), 'reset phase %s/%s' % (phase, momentum), event)
    send(f, selector('release'))

if __name__ == '__main__':
    C.CDLL(sys.argv[1])
    cls = runtime.objc_getClass('WKPolyfillPriv__NSScrollingPredominantAxisFilter')
    if not cls:
        raise RuntimeError('polyfill class missing')
    runtime.class_getInstanceMethod.argtypes = [C.c_void_p, C.c_void_p]
    runtime.class_getInstanceMethod.restype = C.c_void_p
    for name in ('setPredominantAxisMode:', 'resetIfOutOfDate:', 'filterInputScrollEvent:outputDelta:velocity:'):
        if not runtime.class_getInstanceMethod(cls, selector(name)):
            print('FAIL polyfill method missing: ' + name)
            sys.exit(1)
    exercise(lambda: send(send(cls, selector('alloc')), selector('init')))
    print('scrolling-axis-filter: %d checks, %d failures' % (checks, failures))
    sys.exit(bool(failures))
