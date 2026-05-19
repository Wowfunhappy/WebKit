#!/usr/bin/env python3
"""
Patch __objc_classlist section size in WebKit to limit ObjC class registration to ≤72.
10.9 libobjc v228 crashes in _read_images when ≥73 classes are registered per image.
"""
import sys
import struct

def patch_macho(path, max_classes=72):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    
    # Mach-O 64-bit header: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic != 0xfeedfacf:
        print(f"Not a 64-bit Mach-O: magic={magic:08x}")
        return False
    
    ncmds = struct.unpack_from('<I', data, 16)[0]
    sizeofcmds = struct.unpack_from('<I', data, 20)[0]
    
    cmd_offset = 32  # after mach_header_64
    LC_SEGMENT_64 = 0x19
    
    target_size = max_classes * 8
    patched = False
    
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, cmd_offset)
        if cmd == LC_SEGMENT_64:
            segname = data[cmd_offset+8:cmd_offset+24].split(b'\x00')[0].decode()
            nsects = struct.unpack_from('<I', data, cmd_offset+64)[0]
            sect_offset = cmd_offset + 72
            for j in range(nsects):
                sectname = data[sect_offset:sect_offset+16].split(b'\x00')[0].decode()
                # struct section_64: sectname[16], segname[16], addr (8), size (8), offset(4), ...
                size_offset = sect_offset + 40  # sectname(16) + segname(16) + addr(8)
                cur_size = struct.unpack_from('<Q', data, size_offset)[0]
                if sectname == '__objc_classlist':
                    print(f"Found __objc_classlist in {segname}: current size = {cur_size} bytes ({cur_size//8} entries)")
                    if cur_size > target_size:
                        struct.pack_into('<Q', data, size_offset, target_size)
                        print(f"  Patched to {target_size} bytes ({target_size//8} entries)")
                        patched = True
                    else:
                        print(f"  Already ≤{max_classes} entries, no patch needed")
                sect_offset += 80  # sizeof(section_64)
        cmd_offset += cmdsize
    
    if patched:
        with open(path, 'wb') as f:
            f.write(data)
        print(f"Wrote patched binary to {path}")
        return True
    return False

if __name__ == '__main__':
    for path in sys.argv[1:]:
        print(f"=== {path} ===")
        patch_macho(path)
