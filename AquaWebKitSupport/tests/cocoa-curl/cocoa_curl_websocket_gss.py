import ctypes as c
import os

lib = c.CDLL('/System/Library/Frameworks/GSS.framework/GSS')
U = c.c_uint32
P = c.c_void_p

class Buffer(c.Structure):
    _fields_ = [('length', c.c_size_t), ('value', P)]

lib.gsskrb5_register_acceptor_identity.argtypes = [c.c_char_p]
lib.gsskrb5_register_acceptor_identity.restype = U
lib.gss_accept_sec_context.argtypes = [c.POINTER(U), c.POINTER(P), P, c.POINTER(Buffer), P, c.POINTER(P), c.POINTER(P), c.POINTER(Buffer), c.POINTER(U), c.POINTER(U), c.POINTER(P)]
lib.gss_accept_sec_context.restype = U
lib.gss_release_buffer.argtypes = [c.POINTER(U), c.POINTER(Buffer)]
lib.gss_release_name.argtypes = [c.POINTER(U), c.POINTER(P)]
lib.gss_display_name.argtypes = [c.POINTER(U), P, c.POINTER(Buffer), c.POINTER(P)]
lib.gss_delete_sec_context.argtypes = [c.POINTER(U), c.POINTER(P), c.POINTER(Buffer)]
assert not lib.gsskrb5_register_acceptor_identity(os.environ['KRB5_KTNAME'].encode())

class Acceptor:
    def __init__(self):
        self.context = P()
        self.complete = False
        self.client_principal = None

    def step(self, token):
        raw = c.create_string_buffer(token)
        incoming = Buffer(len(token), c.cast(raw, P))
        outgoing = Buffer()
        name = P()
        minor = U()
        major = lib.gss_accept_sec_context(c.byref(minor), c.byref(self.context), None, c.byref(incoming), None, c.byref(name), None, c.byref(outgoing), None, None, None)
        minor_code = minor.value
        result = c.string_at(outgoing.value, outgoing.length) if outgoing.length else b''
        lib.gss_release_buffer(c.byref(minor), c.byref(outgoing))
        if name:
            text = Buffer()
            lib.gss_display_name(c.byref(minor), name, c.byref(text), None)
            self.client_principal = c.string_at(text.value, text.length).decode()
            lib.gss_release_buffer(c.byref(minor), c.byref(text))
            lib.gss_release_name(c.byref(minor), c.byref(name))
        if major not in (0, 1):
            raise RuntimeError('GSS accept failed: major=%#x minor=%#x' % (major, minor_code))
        self.complete = not major
        return result

    def __del__(self):
        if self.context:
            minor = U()
            lib.gss_delete_sec_context(c.byref(minor), c.byref(self.context), None)
