#!/usr/bin/env python3
"""Is there ink on this PNG, and is it the size it should be?

    png-ink.py <file> [min distinct colours] [expected width] [min height]

Exits 0 when the image decodes, is the width it was asked for, is at least the
height it was asked for, and carries at least that many distinct pixel values.
Non-zero otherwise. Prints what it found either way, whichever way it exits.

The width is asserted and the height is only bounded below, because those are
two different facts: a window manager gives a client the width it asked for and
trims the height for its own decorations. Measured under labwc on the headless
backend, 2026-09-12: a 980x760 FloatingWindow's content item grabs as 980x692.
Asserting 760 there would be asserting a number nobody read.

── Why this is here rather than `wc -c` ─────────────────────────────────────

tests/run-privacy-page-test.sh rasterises a settings page and needs to know the
result is not a flat rectangle. A file size cannot answer that: a 980x760 fill
of one colour compresses to a few hundred bytes, and so does a page whose every
binding is correct and which painted nothing — which is precisely the failure
the `pixels` phase exists to catch, since every other assertion in that runner
reads an object tree and would pass over it.

── Why stdlib only ──────────────────────────────────────────────────────────

A PNG is zlib over filtered scanlines and `zlib` is in the standard library, so
this needs no image library on the CI runner. It handles the two colour types
Qt's grab actually writes — 8-bit RGB and 8-bit RGBA — and says so plainly for
anything else rather than guessing.
"""
import struct
import sys
import zlib

CHANNELS = {2: 3, 6: 4}


def chunks(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    i = 8
    while i + 8 <= len(data):
        (length,) = struct.unpack(">I", data[i:i + 4])
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        yield kind, body
        i += 12 + length


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode(path):
    data = open(path, "rb").read()
    width = height = depth = colour = None
    idat = bytearray()
    for kind, body in chunks(data):
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if interlace:
                raise ValueError("interlaced PNGs are not handled")
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None:
        raise ValueError("no IHDR")
    if depth != 8 or colour not in CHANNELS:
        raise ValueError("expected 8-bit RGB or RGBA, got depth %s colour type %s"
                         % (depth, colour))
    n = CHANNELS[colour]
    raw = zlib.decompress(bytes(idat))
    stride = width * n
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if f == 1:
            for i in range(n, stride):
                line[i] = (line[i] + line[i - n]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                left = line[i - n] if i >= n else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                left = line[i - n] if i >= n else 0
                upleft = prev[i - n] if i >= n else 0
                line[i] = (line[i] + paeth(left, prev[i], upleft)) & 0xFF
        elif f != 0:
            raise ValueError("unknown filter %s" % f)
        out += line
        prev = line
    return width, height, n, bytes(out)


def main(argv):
    if not argv:
        print("usage: png-ink.py <file> [min colours] [expected width] [min height]")
        return 2
    want = int(argv[1]) if len(argv) > 1 else 900
    want_w = int(argv[2]) if len(argv) > 2 else 0
    min_h = int(argv[3]) if len(argv) > 3 else 0
    try:
        width, height, n, pixels = decode(argv[0])
    except Exception as exc:                                  # noqa: BLE001
        print("  could not decode %s: %s" % (argv[0], exc))
        return 1
    seen = set()
    for i in range(0, len(pixels), n):
        seen.add(pixels[i:i + n])
    print("  %dx%d, %d channels, %d distinct pixel values (want >= %d)"
          % (width, height, n, len(seen), want))

    bad = []
    if want_w and width != want_w:
        bad.append("width is %d, not the %d the window asked for" % (width, want_w))
    if min_h and height < min_h:
        bad.append("height is %d, under the %d floor" % (height, min_h))
    if len(seen) < want:
        bad.append("only %d distinct pixel values; that is a flat rectangle,"
                   " not a drawn page" % len(seen))
    for line in bad:
        print("  %s" % line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
