#!/usr/bin/env python3
"""Write the corpus index.html checks, into corpus/ beside this file.

Every file carries the same picture: a 16x16 image whose pixel at (x, y) is (x * 16, y * 16, 64),
opaque in the left half and alpha 128 in the right, so one expectation covers every format. The
formats are the ones this port decodes in WebCore -- PNG, animated PNG, GIF, animated GIF, BMP,
ICO, JPEG, and TIFF in six encodings -- and the ones needing an encoder the standard library does
not have are written byte by byte. The alpha is dropped where a format cannot carry it (JPEG, BMP,
the RGB and greyscale TIFFs), and index.html expects opaque there.
"""

import os
import struct
import sys
import zlib

W = H = 16
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus")


def rgba(x, y, width=W, height=H):
    """The corpus picture, at any size: a red ramp across, a green ramp down, constant blue, and
    alpha 255 in the left half against 128 in the right."""
    return (x * (256 // width), y * (256 // height), 64, 255 if x < width // 2 else 128)


def rows(alpha=True):
    for y in range(H):
        yield [rgba(x, y)[: 4 if alpha else 3] for x in range(W)]


# ---------------------------------------------------------------- PNG / APNG

def png_chunk(tag, payload):
    body = tag + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png_idat(alpha=True):
    raw = b""
    for row in rows(alpha):
        raw += b"\x00" + b"".join(bytes(p) for p in row)
    return zlib.compress(raw)


def write_png(path, alpha=True):
    colour_type = 6 if alpha else 2
    data = b"\x89PNG\r\n\x1a\n"
    data += png_chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, colour_type, 0, 0, 0))
    data += png_chunk(b"IDAT", png_idat(alpha))
    data += png_chunk(b"IEND", b"")
    open(path, "wb").write(data)


def write_apng(path):
    """Two frames: the corpus picture, then the same picture with red zeroed."""
    def frame_data(zero_red):
        raw = b""
        for y in range(H):
            raw += b"\x00"
            for x in range(W):
                r, g, b, a = rgba(x, y)
                raw += bytes((0 if zero_red else r, g, b, a))
        return zlib.compress(raw)

    fctl = lambda seq, delay: struct.pack(">IIIIIHHBB", seq, W, H, 0, 0, delay, 100, 0, 0)
    data = b"\x89PNG\r\n\x1a\n"
    data += png_chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
    data += png_chunk(b"acTL", struct.pack(">II", 2, 0))          # 2 frames, loop forever
    data += png_chunk(b"fcTL", fctl(0, 10))
    data += png_chunk(b"IDAT", frame_data(False))                  # frame 0 is the default image
    data += png_chunk(b"fcTL", fctl(1, 10))
    data += png_chunk(b"fdAT", struct.pack(">I", 2) + frame_data(True))
    data += png_chunk(b"IEND", b"")
    open(path, "wb").write(data)


# ---------------------------------------------------------------------- GIF

def gif_bytes(frames):
    """frames: list of index planes over one 256-entry palette. One frame = a static GIF."""
    palette = b"".join(bytes((i, 0, 0)) for i in range(256))
    out = b"GIF89a" + struct.pack("<HHBBB", W, H, 0xF7, 0, 0) + palette
    if len(frames) > 1:
        out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"     # loop forever
    for plane in frames:
        out += b"\x21\xF9\x04\x00\x0A\x00\x00\x00"                 # 100ms, no disposal
        out += b"\x2C" + struct.pack("<HHHHB", 0, 0, W, H, 0)
        # Uncompressed-LZW: 8-bit codes with a clear before every 100 pixels, which every decoder
        # reads and no compressor is needed to write.
        out += b"\x08"
        codes, run = [], []
        for i, index in enumerate(plane):
            if not run:
                codes.append(256)                                  # clear
            run.append(index)
            if len(run) == 100 or i == len(plane) - 1:
                codes.extend(run)
                run = []
        codes.append(257)                                          # end of information
        bits, acc, nbits = b"", 0, 0
        for code in codes:
            acc |= code << nbits
            nbits += 9
            while nbits >= 8:
                bits += bytes((acc & 0xFF,))
                acc >>= 8
                nbits -= 8
        if nbits:
            bits += bytes((acc & 0xFF,))
        for i in range(0, len(bits), 255):
            block = bits[i:i + 255]
            out += bytes((len(block),)) + block
        out += b"\x00"
    return out + b"\x3B"


def write_gif(path, animated=False):
    plane = [rgba(x, y)[0] for y in range(H) for x in range(W)]
    frames = [plane, [0] * (W * H)] if animated else [plane]
    open(path, "wb").write(gif_bytes(frames))


# ---------------------------------------------------------------------- BMP

def bmp_bytes():
    row_bytes = W * 3
    padding = (-row_bytes) % 4
    pixels = b""
    for y in range(H - 1, -1, -1):                                 # BMP rows run bottom-up
        for x in range(W):
            r, g, b, _ = rgba(x, y)
            pixels += bytes((b, g, r))
        pixels += b"\x00" * padding
    header = struct.pack("<IiiHHIIiiII", 40, W, H, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    return b"BM" + struct.pack("<IHHI", 14 + len(header) + len(pixels), 0, 0, 14 + len(header)) + header + pixels


def write_bmp(path):
    open(path, "wb").write(bmp_bytes())


def write_ico(path):
    """One PNG-compressed entry, which is how every icon this size is written now."""
    png = os.path.join(DIR, "corpus.png")
    payload = open(png, "rb").read()
    out = struct.pack("<HHH", 0, 1, 1)
    out += struct.pack("<BBBBHHII", W, H, 0, 0, 1, 32, len(payload), 6 + 16)
    open(path, "wb").write(out + payload)


# --------------------------------------------------------------------- TIFF
#
# A TIFF is a byte-order mark, a pointer to a directory, and directories that point at their pixels.
# The helpers below are that, so every layout the decoder has a branch for -- strips and tiles, one
# block and many, top-origin and bottom-origin, each flavour of alpha -- is a table of tags and a
# block list rather than another encoder.

TIFF_SIZES = {1: 1, 3: 2, 4: 4}
TIFF_CODES = {1: "B", 3: "H", 4: "I"}

ORIENTATION_TOPLEFT = 1
ORIENTATION_BOTLEFT = 4

EXTRASAMPLE_UNSPECIFIED = 0
EXTRASAMPLE_ASSOCALPHA = 1
EXTRASAMPLE_UNASSALPHA = 2


def tiff_ifd_length(entries):
    """The bytes one directory occupies: its count, its entries, its next-pointer, its out-of-line
    values."""
    out_of_line = sum(TIFF_SIZES[k] * c for _, k, c, _ in entries if TIFF_SIZES[k] * c > 4)
    return 2 + 12 * len(entries) + 4 + out_of_line


def tiff_ifd(entries, order, ifd_offset, next_offset):
    entries = sorted(entries)
    values = b""
    value_base = ifd_offset + 2 + 12 * len(entries) + 4
    blob = struct.pack(order + "H", len(entries))
    for tag, kind, count, numbers in entries:
        size = TIFF_SIZES[kind] * count
        packed = struct.pack(order + TIFF_CODES[kind] * count, *numbers)
        if size <= 4:
            field = packed + b"\x00" * (4 - size)
        else:
            field = struct.pack(order + "I", value_base + len(values))
            values += packed
        blob += struct.pack(order + "HHI", tag, kind, count) + field
    return blob + struct.pack(order + "I", next_offset) + values


def write_tiff(path, blocks, directories, order="<"):
    """blocks: one list of byte blocks per page, laid out right after the header. directories: one
    tag-builder per page, called with that page's block offsets and lengths."""
    mark = b"II" if order == "<" else b"MM"
    body = b""
    layout = []
    for page in blocks:
        offsets, lengths = [], []
        for block in page:
            offsets.append(8 + len(body))
            lengths.append(len(block))
            body += block
        layout.append((offsets, lengths))

    ifd_offset = 8 + len(body)
    entries = [build(*layout[i]) for i, build in enumerate(directories)]
    blob = b""
    for i, tags in enumerate(entries):
        this_offset = ifd_offset + len(blob)
        next_offset = this_offset + tiff_ifd_length(tags) if i + 1 < len(entries) else 0
        blob += tiff_ifd(tags, order, this_offset, next_offset)

    open(path, "wb").write(mark + struct.pack(order + "HI", 42, ifd_offset) + body + blob)


def tiff_common_tags(width, height, samples, photometric, offsets, lengths):
    return [
        (256, 3, 1, [width]),                                 # ImageWidth
        (257, 3, 1, [height]),                                # ImageLength
        (258, 3, samples, [8] * samples),                     # BitsPerSample
        (259, 3, 1, [1]),                                     # Compression: none
        (262, 3, 1, [photometric]),                           # PhotometricInterpretation
        (277, 3, 1, [samples]),                               # SamplesPerPixel
        (284, 3, 1, [1]),                                     # PlanarConfiguration: chunky
    ]


def sample_bytes(x, y, width, height, samples, alpha_mode):
    """The corpus pixel, in `samples` channels. alpha_mode says what the fourth one means."""
    r, g, b, a = rgba(x, y, width, height)
    if samples == 1:
        return bytes((g,))
    if samples == 3:
        return bytes((r, g, b))
    if alpha_mode == EXTRASAMPLE_UNASSALPHA:
        return bytes((r, g, b, a))
    # Associated, and the two "libtiff decides" flavours it also reads as associated.
    return bytes(((r * a) // 255, (g * a) // 255, (b * a) // 255, a))


def write_tiff_striped(path, width=W, height=H, rows_per_strip=None, orientation=ORIENTATION_TOPLEFT,
                       samples=3, photometric=2, alpha_mode=None, extra_samples=True, order="<"):
    """A striped page. A bottom-origin orientation stores its rows bottom-up, which is what makes
    the tag meaningful rather than decorative."""
    rows_per_strip = rows_per_strip or height
    bottom_origin = orientation == ORIENTATION_BOTLEFT

    rows = []
    for file_row in range(height):
        y = height - 1 - file_row if bottom_origin else file_row
        rows.append(b"".join(sample_bytes(x, y, width, height, samples, alpha_mode) for x in range(width)))

    strips = [b"".join(rows[i:i + rows_per_strip]) for i in range(0, height, rows_per_strip)]

    def tags(offsets, lengths):
        entries = tiff_common_tags(width, height, samples, photometric, offsets, lengths)
        entries.append((273, 4, len(offsets), offsets))       # StripOffsets
        entries.append((278, 4, 1, [rows_per_strip]))         # RowsPerStrip
        entries.append((279, 4, len(lengths), lengths))       # StripByteCounts
        if orientation != ORIENTATION_TOPLEFT:
            entries.append((274, 3, 1, [orientation]))        # Orientation
        if samples > 3 and extra_samples:
            entries.append((338, 3, 1, [alpha_mode]))         # ExtraSamples
        return entries

    write_tiff(path, [strips], [tags], order)


def write_tiff_tiled(path, width, height, tile_width, tile_length):
    """A tiled page, which is the decoder's other window unit. The tile grid covers the image
    exactly, so no tile needs padding."""
    tiles = []
    for tile_y in range(0, height, tile_length):
        for tile_x in range(0, width, tile_width):
            tile = b""
            for y in range(tile_y, tile_y + tile_length):
                for x in range(tile_x, tile_x + tile_width):
                    tile += sample_bytes(x, y, width, height, 3, None)
            tiles.append(tile)

    def tags(offsets, lengths):
        entries = tiff_common_tags(width, height, 3, 2, offsets, lengths)
        entries.append((322, 3, 1, [tile_width]))             # TileWidth
        entries.append((323, 3, 1, [tile_length]))            # TileLength
        entries.append((324, 4, len(offsets), offsets))       # TileOffsets
        entries.append((325, 4, len(lengths), lengths))       # TileByteCounts
        return entries

    write_tiff(path, [tiles], [tags])


def write_tiff_multipage(path):
    """Two pages: the corpus picture, then its top half."""
    def page(height):
        rows = [b"".join(sample_bytes(x, y, W, H, 3, None) for x in range(W)) for y in range(height)]
        return [b"".join(rows)]

    def tags_for(height):
        def tags(offsets, lengths):
            entries = tiff_common_tags(W, height, 3, 2, offsets, lengths)
            entries.append((273, 4, 1, offsets))
            entries.append((278, 4, 1, [height]))
            entries.append((279, 4, 1, lengths))
            return entries
        return tags

    write_tiff(path, [page(H), page(H // 2)], [tags_for(H), tags_for(H // 2)])


# --------------------------------------------------------------------- JPEG

def write_jpeg(path):
    """sips is the only JPEG encoder on a stock 10.9. It reads the opaque PNG, so what comes back
    is the corpus picture without the alpha JPEG cannot carry."""
    source = os.path.join(DIR, "corpus-opaque.png")
    if os.system("sips -s format jpeg -s formatOptions best '%s' --out '%s' >/dev/null 2>&1" % (source, path)):
        print("  sips could not write %s; the JPEG checks will not run" % os.path.basename(path))


def write_jpeg_oriented(path, orientation):
    """The corpus JPEG with an EXIF Orientation tag in front of it. The pixels are untouched, so
    what the tag asks for is the whole of the difference -- which is what a decoder either applies
    or drops."""
    source = open(os.path.join(DIR, "corpus.jpg"), "rb").read()
    if not source.startswith(b"\xFF\xD8"):
        print("  corpus.jpg is not a JPEG; the oriented variants will not be written")
        return

    # A TIFF header and one directory holding tag 0x0112, wrapped in the Exif APP1 segment.
    ifd = tiff_ifd([(274, 3, 1, [orientation])], "<", 8, 0)
    exif = b"Exif\x00\x00" + b"II" + struct.pack("<HI", 42, 8) + ifd
    segment = b"\xFF\xE1" + struct.pack(">H", len(exif) + 2) + exif

    # The encoder writes an Exif segment of its own, and a reader takes the first one it finds, so
    # the file gets exactly one: the others are dropped and this one goes in behind JFIF.
    out = source[:2]
    offset = 2
    inserted = False
    while offset + 4 <= len(source) and source[offset] == 0xFF:
        marker = source[offset + 1]
        if marker in (0xD8, 0xD9):
            break
        length = (source[offset + 2] << 8) | source[offset + 3]
        chunk = source[offset:offset + 2 + length]
        if marker == 0xE1 and chunk[4:10] == b"Exif\x00\x00":
            offset += 2 + length
            continue
        out += chunk
        offset += 2 + length
        if marker == 0xE0 and not inserted:
            out += segment
            inserted = True
        if marker == 0xDA:                             # start of scan: the entropy-coded data follows
            break
    if not inserted:
        out = source[:2] + segment + out[2:]
    open(path, "wb").write(out + source[offset:])


def main():
    os.makedirs(DIR, exist_ok=True)
    write_png(os.path.join(DIR, "corpus.png"))
    write_png(os.path.join(DIR, "corpus-opaque.png"), alpha=False)
    write_apng(os.path.join(DIR, "corpus-animated.png"))
    write_gif(os.path.join(DIR, "corpus.gif"))
    write_gif(os.path.join(DIR, "corpus-animated.gif"), animated=True)
    write_bmp(os.path.join(DIR, "corpus.bmp"))
    write_ico(os.path.join(DIR, "corpus.ico"))
    write_tiff_striped(os.path.join(DIR, "corpus-rgb.tiff"))
    write_tiff_striped(os.path.join(DIR, "corpus-bigendian.tiff"), order=">")
    write_tiff_striped(os.path.join(DIR, "corpus-gray.tiff"), samples=1, photometric=1)
    write_tiff_striped(os.path.join(DIR, "corpus-unassociated.tiff"), samples=4, alpha_mode=EXTRASAMPLE_UNASSALPHA)
    write_tiff_striped(os.path.join(DIR, "corpus-associated.tiff"), samples=4, alpha_mode=EXTRASAMPLE_ASSOCALPHA)
    # ExtraSamples present but unspecified, and absent altogether: libtiff reads a fourth sample as
    # associated alpha in both, which is the decision the decoder takes its hasAlpha from.
    write_tiff_striped(os.path.join(DIR, "corpus-unspecified-alpha.tiff"), samples=4, alpha_mode=EXTRASAMPLE_UNSPECIFIED)
    write_tiff_striped(os.path.join(DIR, "corpus-no-extrasamples.tiff"), samples=4,
                       alpha_mode=EXTRASAMPLE_ASSOCALPHA, extra_samples=False)
    # Many strips, so the decoder's window loop runs more than once, and bottom-origin pages with
    # one strip and with many, so the mirrored placement of a window runs at all.
    write_tiff_striped(os.path.join(DIR, "corpus-strips.tiff"), rows_per_strip=4)
    write_tiff_striped(os.path.join(DIR, "corpus-bottom.tiff"), orientation=ORIENTATION_BOTLEFT)
    write_tiff_striped(os.path.join(DIR, "corpus-strips-bottom.tiff"), rows_per_strip=4,
                       orientation=ORIENTATION_BOTLEFT)
    # Tiles are the decoder's other window unit, and a 32x32 image over 16x16 tiles is two tile rows.
    write_tiff_tiled(os.path.join(DIR, "corpus-tiled.tiff"), 32, 32, 16, 16)
    write_tiff_multipage(os.path.join(DIR, "corpus-multipage.tiff"))
    write_jpeg(os.path.join(DIR, "corpus.jpg"))
    # EXIF orientation 6 and 8, the two quarter turns, so the decoder's orientation and everything
    # that has to carry or bake it are exercised on a real photo container.
    write_jpeg_oriented(os.path.join(DIR, "corpus-rotated-right.jpg"), 6)
    write_jpeg_oriented(os.path.join(DIR, "corpus-rotated-left.jpg"), 8)
    for name in sorted(os.listdir(DIR)):
        print("  %-28s %d bytes" % (name, os.path.getsize(os.path.join(DIR, name))))


if __name__ == "__main__":
    sys.exit(main())
