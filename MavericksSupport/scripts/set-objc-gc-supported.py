#!/usr/bin/env python
# Set OBJC_IMAGE_SUPPORTS_GC (flags bit 0x2) in every __objc_imageinfo section of the given
# Mach-O files (github issue #118).
#
# 10.9's Objective-C runtime refuses to load an image that lacks this bit into a process
# running garbage collection ("was not compiled with -fobjc-gc or -fobjc-gc-only, but the
# application requires GC" -> abort), which is how apps like Xcode 4 crashed at launch.
# Apple's stock 2013 frameworks all carry flags=0x2, set by compiling -fobjc-gc; modern
# clang removed that mode, so the packaging step sets the same bit post-link. The runtime
# behavior the bit promises is provided by MavericksSupport/polyfill/polyfills/objc-gc.c
# and the GC paths in wtf/RetainPtr.h.
#
# Files without an __objc_imageinfo section (pure C dylibs) are skipped: the runtime only
# checks images that contain Objective-C, and such files have nothing to patch.
#
# Executables (MH_EXECUTE) are skipped entirely: the MAIN image's flags are what DECIDE
# whether a process runs GC -- SUPPORTS_GC on an executable turns collection ON for the
# whole process (flagging our XPC service executables put every WebContent process under
# GC and broke normal Safari browsing). Apple's stock 10.9 XPC service executables carry
# flags=0x0 for the same reason; only the dylibs and frameworks a GC app might load need
# the capability bit.
#
# Usage: set-objc-gc-supported.py <macho-file>...
#        set-objc-gc-supported.py --verify <macho-file>...   (exit 1 unless every file
#                                                             carries the bit somewhere)
#        set-objc-gc-supported.py --require <macho-file>...  (test harness only)
#
# --require additionally sets OBJC_IMAGE_REQUIRES_GC, which makes the runtime turn collection
# ON for a process. It exists for tests/objc-gc, which needs a stand-in for an -fobjc-gc app
# that modern clang can no longer produce, and it is the ONLY reason to touch an executable's
# flags. Never point it at anything we ship.
import struct
import sys

MH_MAGIC_64 = 0xfeedfacf
MH_MAGIC_32 = 0xfeedface
FAT_MAGIC_BE = 0xcafebabe
MH_EXECUTE = 0x2
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
OBJC_IMAGE_SUPPORTS_GC = 0x2
OBJC_IMAGE_REQUIRES_GC = 0x4


def patch_slice(data, base, require=False):
    """Set the flag(s) in one thin Mach-O at offset `base`. True if the file changed."""
    magic = struct.unpack_from('<I', data, base)[0]
    if magic == MH_MAGIC_64:
        ncmds = struct.unpack_from('<I', data, base + 16)[0]
        off = base + 32
    elif magic == MH_MAGIC_32:
        ncmds = struct.unpack_from('<I', data, base + 16)[0]
        off = base + 28
    else:
        raise ValueError('not a little-endian Mach-O at offset 0x%x' % base)
    # Never flag a main executable, because that turns GC ON for its process. The one
    # exception is --require, whose entire purpose is to build such a process for the test.
    if not require and struct.unpack_from('<I', data, base + 12)[0] == MH_EXECUTE:
        return False
    wanted = OBJC_IMAGE_SUPPORTS_GC | (OBJC_IMAGE_REQUIRES_GC if require else 0)
    changed = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd in (LC_SEGMENT, LC_SEGMENT_64):
            is64 = cmd == LC_SEGMENT_64
            segname = bytes(data[off + 8:off + 24]).rstrip(b'\0')
            if segname.startswith(b'__DATA'):
                nsects = struct.unpack_from('<I', data, off + (64 if is64 else 48))[0]
                sect_base = off + (72 if is64 else 56)
                sect_size = 80 if is64 else 68
                for i in range(nsects):
                    so = sect_base + i * sect_size
                    sectname = bytes(data[so:so + 16]).rstrip(b'\0')
                    if sectname == b'__objc_imageinfo':
                        fileoff = struct.unpack_from('<I', data, so + (48 if is64 else 40))[0]
                        loc = base + fileoff
                        version, flags = struct.unpack_from('<II', data, loc)
                        if (flags & wanted) != wanted:
                            struct.pack_into('<II', data, loc, version, flags | wanted)
                            changed = True
        off += cmdsize
    return changed


def patch_file(path, require=False):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if len(data) < 8:
        return
    changed = False
    if struct.unpack_from('>I', data, 0)[0] == FAT_MAGIC_BE:
        nfat = struct.unpack_from('>I', data, 4)[0]
        for i in range(nfat):
            offset = struct.unpack_from('>I', data, 8 + i * 20 + 8)[0]
            changed |= patch_slice(data, offset, require)
    else:
        magic = struct.unpack_from('<I', data, 0)[0]
        if magic not in (MH_MAGIC_64, MH_MAGIC_32):
            return  # not a Mach-O (a script, a resource); nothing to do
        changed = patch_slice(data, 0, require)
    if changed:
        with open(path, 'wb') as f:
            f.write(data)
        print('  GC-flagged%s %s' % (' (REQUIRES)' if require else '', path))


def imageinfo_offset(data, base):
    """File offset of this thin Mach-O's __objc_imageinfo, or None."""
    magic = struct.unpack_from('<I', data, base)[0]
    is64 = magic == MH_MAGIC_64
    off = base + (32 if is64 else 28)
    ncmds = struct.unpack_from('<I', data, base + 16)[0]
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd in (LC_SEGMENT, LC_SEGMENT_64):
            seg64 = cmd == LC_SEGMENT_64
            segname = bytes(data[off + 8:off + 24]).rstrip(b'\0')
            if segname.startswith(b'__DATA'):
                nsects = struct.unpack_from('<I', data, off + (64 if seg64 else 48))[0]
                sect_base = off + (72 if seg64 else 56)
                sect_size = 80 if seg64 else 68
                for i in range(nsects):
                    so = sect_base + i * sect_size
                    if bytes(data[so:so + 16]).rstrip(b'\0') == b'__objc_imageinfo':
                        fileoff = struct.unpack_from('<I', data, so + (48 if seg64 else 40))[0]
                        return base + fileoff
        off += cmdsize
    return None


def has_imageinfo(data, base):
    return imageinfo_offset(data, base) is not None


def slice_flagged(data, base):
    """True if the thin Mach-O at `base` has an __objc_imageinfo with SUPPORTS_GC set."""
    loc = imageinfo_offset(data, base)
    if loc is None:
        return False
    flags = struct.unpack_from('<I', data, loc + 4)[0]
    return bool(flags & OBJC_IMAGE_SUPPORTS_GC)


def slice_needs_flag(data, base):
    """True if this thin Mach-O is a non-executable carrying an __objc_imageinfo."""
    if struct.unpack_from('<I', data, base + 12)[0] == MH_EXECUTE:
        return False
    return has_imageinfo(data, base)


def file_verdict(path):
    """('ok'|'unflagged'|'skip') -- 'skip' means the file has no ObjC content to flag."""
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if len(data) < 8:
        return 'skip'
    if struct.unpack_from('>I', data, 0)[0] == FAT_MAGIC_BE:
        nfat = struct.unpack_from('>I', data, 4)[0]
        bases = [struct.unpack_from('>I', data, 8 + i * 20 + 8)[0] for i in range(nfat)]
    else:
        if struct.unpack_from('<I', data, 0)[0] not in (MH_MAGIC_64, MH_MAGIC_32):
            return 'skip'
        bases = [0]
    # Only the slices we actually build are ours to flag; the grafted stock i386 slices were
    # compiled -fobjc-gc by Apple and already carry the bit.
    needing = [b for b in bases if slice_needs_flag(data, b)]
    if not needing:
        return 'skip'
    return 'ok' if all(slice_flagged(data, b) for b in needing) else 'unflagged'


def main(argv):
    args = argv[1:]
    if args and args[0] == '--verify':
        failed = 0
        checked = 0
        for path in args[1:]:
            verdict = file_verdict(path)
            if verdict == 'skip':
                continue
            checked += 1
            if verdict == 'unflagged':
                sys.stderr.write('ERROR: %s does not carry OBJC_IMAGE_SUPPORTS_GC\n' % path)
                failed = 1
        if not checked:
            sys.stderr.write('ERROR: --verify examined no Objective-C images; the sweep or '
                             'the file list is broken\n')
            failed = 1
        else:
            print('  verified: %d Objective-C image(s) carry OBJC_IMAGE_SUPPORTS_GC' % checked)
        return failed
    require = False
    if args and args[0] == '--require':
        require = True
        args = args[1:]
    for path in args:
        patch_file(path, require)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
