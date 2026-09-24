"""Make metric-only variations of the existing layout-test fonts."""
import struct
import sys
import zlib
from pathlib import Path


def tables(path):
    data = Path(path).read_bytes()
    if data[:4] == b"wOFF":
        result = {}
        for i in range(struct.unpack_from(">H", data, 12)[0]):
            tag, offset, compressed, length, _ = struct.unpack_from(">4sIIII", data, 44 + i * 20)
            body = data[offset:offset + compressed]
            result[tag] = zlib.decompress(body) if compressed < length else body
        return result
    return {tag: data[offset:offset + length] for tag, _, offset, length in
            (struct.unpack_from(">4sIII", data, 12 + i * 16)
             for i in range(struct.unpack_from(">H", data, 4)[0]))}


def checksum(data):
    data += b"\0" * (-len(data) % 4)
    return sum(struct.unpack(">" + "I" * (len(data) // 4), data)) & 0xffffffff


def write(path, source):
    source = dict(source)
    head = bytearray(source[b"head"])
    head[8:12] = b"\0" * 4
    source[b"head"] = bytes(head)
    power = 1 << (len(source).bit_length() - 1)
    output = bytearray(struct.pack(">IHHHH", 0x10000, len(source), power * 16,
                                   power.bit_length() - 1, (len(source) - power) * 16))
    offset = 12 + 16 * len(source)
    bodies = bytearray()
    head_offset = None
    for tag, body in sorted(source.items()):
        if tag == b"head":
            head_offset = offset
        output.extend(struct.pack(">4sIII", tag, checksum(body), offset, len(body)))
        padded = body + b"\0" * (-len(body) % 4)
        bodies.extend(padded)
        offset += len(padded)
    output.extend(bodies)
    struct.pack_into(">I", output, head_offset + 8, (0xb1b0afba - checksum(output)) & 0xffffffff)
    Path(path).write_bytes(output)


out = Path(sys.argv[1])
variable = tables(sys.argv[2])
write(out / "variable.ttf", variable)
cap = dict(variable)
mvar = bytearray(variable[b"MVAR"])
assert mvar[12:16] == b"xhgt" and struct.unpack_from(">H", mvar, 8)[0] == 1
mvar[12:16] = b"cpht"
cap[b"MVAR"] = bytes(mvar)
write(out / "variable-cap.ttf", cap)

# A constant avar2 region remaps the default master to wght=700, wdth=89.9993896484375.
# The reference font's static hmtx/glyf value there is 1532 (fontTools), and its
# inclusive conditional feature selects H.condensed. MVAR also adjusts the cap height.
def constant_store(deltas):
    regions = struct.pack(">HH", 3, 1) + b"\0" * 18
    data = struct.pack(">HHHH", len(deltas), 1, 1, 0) + struct.pack(">" + "h" * len(deltas), *deltas)
    return struct.pack(">HIHI", 1, 12, 1, 12 + len(regions)) + regions + data

origin = tables(sys.argv[3])
index_map = struct.pack(">BBHIII", 0, 0x3f, 3, 0, 1, 0xffffffff)
origin[b"avar"] = struct.pack(">HHHHII", 2, 0, 0, 0, 16, 16 + len(index_map)) + index_map + constant_store([8192, -3277])
origin[b"MVAR"] = struct.pack(">HHHHHH4sHH", 1, 0, 0, 8, 1, 20, b"cpht", 0, 0) + constant_store([100])
write(out / "remapped-origin.ttf", origin)
