"""Golden QR matrices for tests/qr-test.js, from an independent encoder.

Run it as::

    python3 -m venv v && v/bin/pip install segno==1.6.6
    v/bin/python tests/fixtures/gen-qr-vectors.py tests/fixtures/qr-vectors.json

── Why the oracle is patched, and why that is not cheating ───────────────────

segno is the independent implementation this suite checks apex-shell's encoder
against. It is used here with ONE correction, applied below as
`iso_write_padding_bits`, because segno 1.6.6 deviates from ISO/IEC 18004 in
the padding path. Its own source quotes the clause and then drops the
condition in it. segno/encoder.py::write_padding_bits reads:

    # ISO/IEC 18004:2015(E) - 7.4.10 Bit stream to codeword conversion
    # [...] If the bit stream length is such that it does not end at a
    # codeword boundary, padding bits with binary value 0 shall be added
    # after the final bit [...] to extend it to the codeword boundary. [...]
    if version not in (consts.VERSION_M1, consts.VERSION_M3):
        buff.extend([0] * (8 - (length % 8)))

The comment says "if [...] it does not end at a codeword boundary". The code
has no such `if`, so when the stream ALREADY ends on a boundary it appends
`8 - 0 == 8` zero bits — a whole spurious 0x00 codeword where §7.4.10 requires
the pad codewords 11101100 / 00010001. In byte mode this is not an edge case
but the only case: the header is 4 mode bits plus an 8- or 16-bit count, so
the stream is always 4 bits past a boundary, the 4-bit terminator always lands
it exactly on one, and segno therefore always emits one stray 0x00 before the
0xec/0x11 run. Nayuki's reference implementation writes the same step as
`(8 - len % 8) % 8`, with the modulo that segno is missing.

It is invisible in practice — a decoder stops at the terminator and never
reads a pad codeword — which is why it has survived. It is not invisible to a
byte-for-byte comparison, so it would otherwise force apex-shell's encoder to
reproduce a bug in order to pass.

Two things keep this honest, and both are checked rather than asserted in
prose:

  * The patch is derived, not assumed. This script builds every case TWICE,
    once with stock segno and once corrected, and writes the names of the
    cases that differ into `_iso_corrected`. If segno fixes this upstream, the
    list comes back empty on the next regeneration.
  * `_iso_corrected` is pinned by tests/qr-test.js, which asserts the list is
    exactly the four byte-mode cases that carry padding. A correction that
    started touching a case it has no business touching fails there.

Everything else is stock segno: all 32 cases that fill their symbol to
capacity have no padding at all, so the patch cannot reach them, and they are
compared byte-for-byte against an oracle this file did not influence.
"""

import json, sys, base64
import segno
import segno.encoder

_stock_write_padding_bits = segno.encoder.write_padding_bits


def iso_write_padding_bits(buff, version, length):
    """§7.4.10, with the condition segno's own comment states.

    Extend the bit stream with 0 bits *as necessary* to reach a codeword
    boundary. None are necessary when it already ends on one.
    """
    if version not in (segno.consts.VERSION_M1, segno.consts.VERSION_M3):
        if length % 8:
            buff.extend([0] * (8 - (length % 8)))


def capacity(version, error):
    """Largest byte-mode payload this version and level actually take."""
    lo, hi = 1, 3000
    best = 0
    while lo <= hi:
        mid = (lo + hi) // 2
        try:
            segno.make("A" * mid, version=version, error=error, mode="byte",
                       boost_error=False, micro=False)
            best, lo = mid, mid + 1
        except segno.DataOverflowError:
            hi = mid - 1
    return best


def realistic(n_lan, relay):
    """Exactly the field set of apex_remote_core::pairing::PairingOffer, behind
    the SCHEME that crate declares. A fixture that encoded some other shape
    would prove the encoder works on a payload APEX never produces."""
    offer = {
        "v": 1, "machine": "l16",
        "key": base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("="),
        "token": base64.urlsafe_b64encode(bytes(range(32, 64))).decode().rstrip("="),
        "lan": ["192.168.1.%d:7717" % (20 + i) for i in range(n_lan)],
        "relay": relay,
        "expires_ms": 1789155000000,
    }
    body = json.dumps(offer, separators=(",", ":")).encode()
    return "apex-remote:" + base64.urlsafe_b64encode(body).decode().rstrip("=")


P1 = realistic(1, None)
P2 = realistic(3, "wss://apex-remote-relay.andre.workers.dev")


def smallest_version(payload):
    for v in range(1, 41):
        try:
            segno.make(payload, version=v, error="l", mode="byte", boost_error=False)
            return v
        except segno.DataOverflowError:
            pass
    raise AssertionError("no version holds %d bytes" % len(payload))


def build():
    """Every case, against whichever segno.encoder.write_padding_bits is
    installed. Called once per variant, so the two runs cannot drift."""
    cases = []

    def add(name, payload, version, error, mask):
        q = segno.make(payload, version=version, error=error, mode="byte",
                       mask=mask, boost_error=False, micro=False)
        assert q.version == version and q.mode == "byte" and q.mask == mask, name
        assert all(ord(c) < 128 for c in payload), name
        m = [[int(b) for b in row] for row in q.matrix]
        assert len(m) == 17 + 4 * version, (name, len(m))
        cases.append({"name": name, "payload": payload, "version": version,
                      "error": error, "mask": mask, "size": len(m), "matrix": m})

    def full(name, version, error, mask, ch="A"):
        """A payload that fills the symbol exactly, so there is no padding."""
        add(name, ch * capacity(version, error), version, error, mask)

    # ── one version at every mask, and the first version that carries a
    #    version-information block (7) gets all eight.
    for mask in range(8):
        full("v1-l-m%d" % mask, 1, "l", mask)
        full("v7-l-m%d" % mask, 7, "l", mask, "d")

    # ── a spread of versions, so the block layout and the alignment-pattern
    #    tables are exercised where they change.
    for v, mask in [(2, 0), (5, 2), (6, 1), (10, 4), (15, 1), (20, 6), (25, 5), (40, 3)]:
        full("v%d-l-m%d" % (v, mask), v, "l", mask, "e")

    # ── the other three error levels, where the interleaving differs.
    for v, e, mask in [(1, "m", 0), (5, "m", 5), (10, "m", 2),
                       (2, "q", 7), (13, "q", 3), (1, "h", 1), (9, "h", 1), (22, "h", 4)]:
        full("v%d-%s-m%d" % (v, e, mask), v, e, mask, "f")

    # ── payloads short of capacity, so the terminator and the 0xec/0x11 pad
    #    bytes are exercised rather than being absent. These four are the ones
    #    the ISO correction above reaches, and nothing else is.
    add("v10-l-m0-short", "short payload, plenty of padding after it", 10, "l", 0)
    add("v4-l-m0-oneshort", "A" * (capacity(4, "l") - 1), 4, "l", 0)

    # ── and the real thing: what an APEX pairing code actually looks like.
    add("offer-lan-only", P1, smallest_version(P1), "l", 0)
    add("offer-with-relay", P2, smallest_version(P2), "l", 0)
    return cases


segno.encoder.write_padding_bits = _stock_write_padding_bits
stock = build()

segno.encoder.write_padding_bits = iso_write_padding_bits
corrected = build()

assert [c["name"] for c in stock] == [c["name"] for c in corrected]
iso_corrected = [a["name"] for a, b in zip(stock, corrected) if a != b]

json.dump({
  "_comment": "Golden QR matrices. GENERATED, do not edit by hand.",
  "_generated_by":
      "segno %s, with encoder.write_padding_bits corrected per ISO/IEC 18004 "
      "7.4.10 -- see the header of gen-qr-vectors.py. The correction changes "
      "exactly the cases named in _iso_corrected and no others; every case "
      "not named there is stock segno output." % segno.__version__,
  "_iso_corrected": iso_corrected,
  "_regenerate": "python3 -m venv v && v/bin/pip install segno==1.6.6 && "
                 "v/bin/python tests/fixtures/gen-qr-vectors.py tests/fixtures/qr-vectors.json",
  "_call": "segno.make(payload, version=V, error=E, mode='byte', mask=M, boost_error=False, micro=False).matrix",
  "_rows": "top to bottom, no quiet zone, 1 = dark",
  "cases": corrected,
}, open(sys.argv[1], "w"), separators=(",", ":"))

print("cases:", len(corrected))
print("versions:", sorted({c["version"] for c in corrected}))
print("ISO-corrected away from stock segno:", len(iso_corrected), iso_corrected)
print("offer payload lengths:", len(P1), "->v%d" % smallest_version(P1),
      "|", len(P2), "->v%d" % smallest_version(P2))
