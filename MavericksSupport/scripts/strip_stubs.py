#!/usr/bin/env python3
"""Remove specific symbols from a Mach-O object file by marking them as undefined."""
import sys
import struct

# Mach-O constants
MH_MAGIC_64 = 0xfeedfacf
LC_SYMTAB = 0x2

N_UNDF = 0x0
N_EXT = 0x01
N_TYPE = 0x0e
N_SECT = 0xe

def patch_object(path, symbols_to_undefine):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic != MH_MAGIC_64:
        print(f"Not a 64-bit Mach-O object: magic={magic:08x}")
        return False
    
    ncmds = struct.unpack_from('<I', data, 16)[0]
    
    cmd_offset = 32  # after mach_header_64
    symtab_off = symtab_strs = symtab_nsyms = symtab_stroff = None
    
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, cmd_offset)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', data, cmd_offset+8)
            symtab_off = symoff
            symtab_nsyms = nsyms
            symtab_stroff = stroff
            symtab_strs = bytes(data[stroff:stroff+strsize])
            break
        cmd_offset += cmdsize
    
    if symtab_off is None:
        print("No LC_SYMTAB!")
        return False
    
    # Build symbol name map
    matched = []
    for i in range(symtab_nsyms):
        sym_off = symtab_off + i * 16  # nlist_64 = 16 bytes
        name_off = struct.unpack_from('<I', data, sym_off)[0]
        n_type = data[sym_off + 4]
        n_sect = data[sym_off + 5]
        end = symtab_strs.find(b'\x00', name_off)
        name = symtab_strs[name_off:end].decode('ascii', errors='replace')
        if name in symbols_to_undefine:
            # Mark as undefined: type = N_UNDF | N_EXT, sect = 0, value = 0
            data[sym_off + 4] = N_UNDF | N_EXT  # type
            data[sym_off + 5] = 0  # section
            # Zero out the value (8 bytes at offset 8)
            struct.pack_into('<Q', data, sym_off + 8, 0)
            matched.append(name)
    
    if matched:
        with open(path, 'wb') as f:
            f.write(data)
        print(f"Marked {len(matched)} symbols as undefined in {path}")
        for n in matched[:5]:
            print(f"  - {n}")
    else:
        print(f"No matching symbols found in {path}")
    
    return bool(matched)

if __name__ == '__main__':
    syms = {
        '_ZN7WebCore23collectScreenPropertiesEv',
    }
    for path in sys.argv[1:]:
        patch_object(path, syms)
