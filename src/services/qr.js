// ─── qr.js ───────────────────────────────────────────────────────────────────
// A QR encoder, ISO/IEC 18004, byte mode, versions 1–40, all four error
// correction levels.
//
// ── Why this exists at all ───────────────────────────────────────────────────
//
// P1-051's first criterion is a pairing code a phone can scan, shown by APEX
// Shell. `apex remote pair` deliberately refuses to draw one in the terminal
// and says why in its own source: "no encoder is vendored, and a wrong QR is
// worse than none — a phone scans it, fails, and the person concludes their
// camera is broken." That sentence is the whole specification for this file.
// It is not enough for the output to look like a QR code.
//
// ── How it is known to be right ──────────────────────────────────────────────
//
// Every one of the 36 cases in tests/fixtures/qr-vectors.json is a matrix
// produced by segno 1.6.6 — an independent, widely used implementation — with
// version, mode, mask and error level all pinned so there is exactly one
// correct answer. tests/qr-test.js compares this encoder against every module
// of every one of them: versions 1 through 40, all four levels, all eight
// masks at two versions, the padding path, and the two payloads an actual
// APEX pairing code produces.
//
// Thirty-two of those 36 are stock segno. The other four are segno with a
// one-line correction, because segno 1.6.6 appends a spurious 0x00 codeword
// where ISO/IEC 18004 §7.4.10 requires the 0xec/0x11 pad bytes — its own
// source quotes the clause and drops the condition in it. The four are exactly
// the cases carrying padding; the correction cannot reach the other 32, which
// fill their symbol to capacity and have no padding at all. The generator
// derives that list by building every case twice and diffing, rather than
// being told it, and qr-test.js pins both the list and the underlying rule.
// tests/fixtures/gen-qr-vectors.py's header is the full account.
//
// That is the same shape as the rest of this program's evidence: the trust
// gate was proven against a CA minted for the purpose rather than against
// production sigstore, and the relay against a local double. The fixtures are
// EVIDENCE, not a dependency — nothing at run time or test time needs segno,
// and the venv it came from is a scratch directory that no longer exists.
//
// ── Why not a library ────────────────────────────────────────────────────────
//
// apex-shell vendors no JavaScript and has no package manager in its build;
// `src/services/` is hand-written .js that both QML and `node` load directly.
// A QR encoder is one file with no I/O and a total specification, which is the
// kind of thing this tree has repeatedly chosen to write rather than depend on
// — see net.rs on getifaddrs, and apex-secretd on curl.
//
// Nothing here does I/O, knows about Theme, or touches Quickshell. Data in,
// data out, so `node` can drive all of it.

// ── the field ───────────────────────────────────────────────────────────────
// GF(256) with the QR code's primitive polynomial x^8 + x^4 + x^3 + x^2 + 1.
function gfMul(a, b) {
    var z = 0
    for (var i = 7; i >= 0; i--) {
        z = (z << 1) ^ ((z >>> 7) * 0x11d)
        z ^= ((b >>> i) & 1) * a
    }
    return z & 0xff
}

// The generator polynomial for `degree` error-correction codewords:
// (x - r^0)(x - r^1)…(x - r^(degree-1)), coefficients highest power first,
// with the leading 1 left off because it is always 1.
function generator(degree) {
    var result = []
    for (var i = 0; i < degree; i++) result.push(0)
    result[degree - 1] = 1
    var root = 1
    for (var i = 0; i < degree; i++) {
        for (var j = 0; j < degree; j++) {
            result[j] = gfMul(result[j], root)
            if (j + 1 < degree) result[j] ^= result[j + 1]
        }
        root = gfMul(root, 0x02)
    }
    return result
}

// The remainder of `data` divided by the generator of that degree — the error
// correction codewords for one block.
function remainder(data, degree) {
    var gen = generator(degree)
    var result = []
    for (var i = 0; i < degree; i++) result.push(0)
    for (var i = 0; i < data.length; i++) {
        var factor = data[i] ^ result.shift()
        result.push(0)
        for (var j = 0; j < gen.length; j++) result[j] ^= gfMul(gen[j], factor)
    }
    return result
}

// ── the specification's two tables ──────────────────────────────────────────
// Indexed [level][version]; entry 0 of each row is unused. These are the only
// numbers in this file that cannot be derived, and they are exactly what the
// fixture comparison checks: a wrong entry changes the block layout and every
// module after it.
var LEVELS = ["l", "m", "q", "h"]

var ECC_PER_BLOCK = {
    l: [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
        28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    m: [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
        26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    q: [0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
        28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    h: [0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
        30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
}

var BLOCKS = {
    l: [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
        8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    m: [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
        17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    q: [0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
        23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    h: [0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
        25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
}

// Which two bits the level is written as in the format information. NOT the
// order the levels are usually listed in: L is 1 and M is 0, and getting this
// backwards produces a code every scanner rejects.
var FORMAT_BITS = { l: 1, m: 0, q: 3, h: 2 }

// ── geometry ────────────────────────────────────────────────────────────────
function size(version) {
    return version * 4 + 17
}

// Every module in the symbol, minus the function patterns and the format and
// version information. Derived rather than tabulated.
function rawDataModules(version) {
    var result = (16 * version + 128) * version + 64
    if (version >= 2) {
        var numAlign = Math.floor(version / 7) + 2
        result -= (25 * numAlign - 10) * numAlign - 55
        if (version >= 7) result -= 36
    }
    return result
}

function dataCodewords(version, level) {
    return Math.floor(rawDataModules(version) / 8) -
        ECC_PER_BLOCK[level][version] * BLOCKS[level][version]
}

// The centres of the alignment patterns, ascending. Version 1 has none, and
// version 32's step is the one the general formula gets wrong.
function alignmentPositions(version) {
    if (version === 1) return []
    var numAlign = Math.floor(version / 7) + 2
    var step = version === 32 ? 26
        : Math.floor((version * 4 + numAlign * 2 + 1) / (numAlign * 2 - 2)) * 2
    var result = []
    for (var pos = size(version) - 7; result.length < numAlign - 1; pos -= step) {
        result.unshift(pos)
    }
    result.unshift(6)
    return result
}

// ── the bit stream ──────────────────────────────────────────────────────────
// Byte mode only. The pairing payload is `apex-remote:` followed by URL-safe
// base64, which alphanumeric mode cannot carry — it has no lower case — so
// choosing a mode is not a decision this has to make.
function segmentBits(bytes, version) {
    var bits = []
    function put(value, width) {
        for (var i = width - 1; i >= 0; i--) bits.push((value >>> i) & 1)
    }
    put(0x4, 4)                                  // byte mode
    put(bytes.length, version <= 9 ? 8 : 16)     // the count field widens at 10
    for (var i = 0; i < bytes.length; i++) put(bytes[i], 8)
    return bits
}

function toBytes(text) {
    // UTF-8. A pairing payload is ASCII by construction, but a machine name
    // is not necessarily, and a QR code carrying mojibake is one that pairs a
    // phone with a machine whose name is wrong.
    var out = []
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i)
        if (c < 0x80) {
            out.push(c)
        } else if (c < 0x800) {
            out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f))
        } else if (c >= 0xd800 && c < 0xdc00 && i + 1 < text.length) {
            var full = 0x10000 + ((c - 0xd800) << 10) + (text.charCodeAt(++i) - 0xdc00)
            out.push(0xf0 | (full >> 18), 0x80 | ((full >> 12) & 0x3f),
                     0x80 | ((full >> 6) & 0x3f), 0x80 | (full & 0x3f))
        } else {
            out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f))
        }
    }
    return out
}

function smallestVersion(bytes, level) {
    for (var v = 1; v <= 40; v++) {
        var capacity = dataCodewords(v, level) * 8
        var needed = 4 + (v <= 9 ? 8 : 16) + bytes.length * 8
        if (needed <= capacity) return v
    }
    return 0
}

// Terminator, byte alignment, then the two pad bytes, alternating.
function padded(bits, version, level) {
    var capacity = dataCodewords(version, level) * 8
    var out = bits.slice(0)
    for (var i = 0; i < 4 && out.length < capacity; i++) out.push(0)
    while (out.length % 8 !== 0) out.push(0)
    var codewords = []
    for (var i = 0; i < out.length; i += 8) {
        var byte = 0
        for (var j = 0; j < 8; j++) byte = (byte << 1) | out[i + j]
        codewords.push(byte)
    }
    for (var pad = 0xec; codewords.length < capacity / 8; pad ^= 0xec ^ 0x11) {
        codewords.push(pad)
    }
    return codewords
}

// Split into blocks, add the error correction, and interleave.
//
// The short blocks come first and the long ones after, and the interleave
// steps over the position the short blocks do not have. Reading them in the
// wrong order produces a symbol whose every codeword is right and whose
// arrangement is wrong, which no scanner recovers.
function interleave(data, version, level) {
    var numBlocks = BLOCKS[level][version]
    var eccLen = ECC_PER_BLOCK[level][version]
    var rawCodewords = Math.floor(rawDataModules(version) / 8)
    var shortBlocks = numBlocks - rawCodewords % numBlocks
    var shortLen = Math.floor(rawCodewords / numBlocks) - eccLen

    var blocks = []
    for (var i = 0, k = 0; i < numBlocks; i++) {
        var len = shortLen + (i < shortBlocks ? 0 : 1)
        var block = data.slice(k, k + len)
        k += len
        blocks.push({ data: block, ecc: remainder(block, eccLen) })
    }

    var result = []
    for (var i = 0; i < shortLen + 1; i++) {
        for (var j = 0; j < blocks.length; j++) {
            if (i < shortLen || j >= shortBlocks) result.push(blocks[j].data[i])
        }
    }
    for (var i = 0; i < eccLen; i++) {
        for (var j = 0; j < blocks.length; j++) result.push(blocks[j].ecc[i])
    }
    return result
}

// ── the symbol ──────────────────────────────────────────────────────────────
function blank(n) {
    var m = []
    for (var y = 0; y < n; y++) {
        var row = []
        for (var x = 0; x < n; x++) row.push(0)
        m.push(row)
    }
    return m
}

function Symbol_(version) {
    this.version = version
    this.size = size(version)
    this.modules = blank(this.size)
    this.reserved = blank(this.size)
}

Symbol_.prototype.set = function (x, y, dark, isFunction) {
    this.modules[y][x] = dark ? 1 : 0
    if (isFunction) this.reserved[y][x] = 1
}

Symbol_.prototype.finder = function (cx, cy) {
    for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
            var d = Math.max(Math.abs(dx), Math.abs(dy))
            var x = cx + dx, y = cy + dy
            if (x >= 0 && x < this.size && y >= 0 && y < this.size) {
                this.set(x, y, d !== 2 && d !== 4, true)
            }
        }
    }
}

Symbol_.prototype.alignment = function (cx, cy) {
    for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
            this.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1, true)
        }
    }
}

Symbol_.prototype.functionPatterns = function () {
    for (var i = 0; i < this.size; i++) {
        this.set(6, i, i % 2 === 0, true)
        this.set(i, 6, i % 2 === 0, true)
    }
    this.finder(3, 3)
    this.finder(this.size - 4, 3)
    this.finder(3, this.size - 4)

    var align = alignmentPositions(this.version)
    for (var i = 0; i < align.length; i++) {
        for (var j = 0; j < align.length; j++) {
            // Not over the three finder patterns.
            var corner = (i === 0 && j === 0) || (i === 0 && j === align.length - 1) ||
                (i === align.length - 1 && j === 0)
            if (!corner) this.alignment(align[i], align[j])
        }
    }

    this.formatBits(0, "l")   // reserved now, written for real after masking
    this.versionBits()
}

// BCH(15,5) over the five bits of level-and-mask, then XOR with the constant
// that stops an all-zero symbol from having all-zero format information.
Symbol_.prototype.formatBits = function (mask, level) {
    var data = (FORMAT_BITS[level] << 3) | mask
    var rem = data
    for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537)
    var bits = ((data << 10) | rem) ^ 0x5412

    for (var i = 0; i <= 5; i++) this.set(8, i, (bits >>> i) & 1, true)
    this.set(8, 7, (bits >>> 6) & 1, true)
    this.set(8, 8, (bits >>> 7) & 1, true)
    this.set(7, 8, (bits >>> 8) & 1, true)
    for (var i = 9; i < 15; i++) this.set(14 - i, 8, (bits >>> i) & 1, true)

    for (var i = 0; i < 8; i++) this.set(this.size - 1 - i, 8, (bits >>> i) & 1, true)
    for (var i = 8; i < 15; i++) this.set(8, this.size - 15 + i, (bits >>> i) & 1, true)
    // The one module that is always dark, and is not part of any pattern.
    this.set(8, this.size - 8, 1, true)
}

// BCH(18,6). Only from version 7 up; below that there is no block to write.
Symbol_.prototype.versionBits = function () {
    if (this.version < 7) return
    var rem = this.version
    for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25)
    var bits = (this.version << 12) | rem
    for (var i = 0; i < 18; i++) {
        var bit = (bits >>> i) & 1
        var a = this.size - 11 + (i % 3)
        var b = Math.floor(i / 3)
        this.set(a, b, bit, true)
        this.set(b, a, bit, true)
    }
}

// Two modules wide, bottom to top then top to bottom, right to left, stepping
// over column 6 because the vertical timing pattern is there.
Symbol_.prototype.codewords = function (data) {
    var i = 0
    for (var right = this.size - 1; right >= 1; right -= 2) {
        if (right === 6) right = 5
        for (var vert = 0; vert < this.size; vert++) {
            for (var j = 0; j < 2; j++) {
                var x = right - j
                var upward = ((right + 1) & 2) === 0
                var y = upward ? this.size - 1 - vert : vert
                if (!this.reserved[y][x] && i < data.length * 8) {
                    this.modules[y][x] = (data[i >>> 3] >>> (7 - (i & 7))) & 1
                    i++
                }
                // Any remainder bits are left at zero, which is what the
                // specification says to do with them.
            }
        }
    }
}

var MASKS = [
    function (x, y) { return (x + y) % 2 === 0 },
    function (x, y) { return y % 2 === 0 },
    function (x, y) { return x % 3 === 0 },
    function (x, y) { return (x + y) % 3 === 0 },
    function (x, y) { return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0 },
    function (x, y) { return (x * y) % 2 + (x * y) % 3 === 0 },
    function (x, y) { return ((x * y) % 2 + (x * y) % 3) % 2 === 0 },
    function (x, y) { return ((x + y) % 2 + (x * y) % 3) % 2 === 0 }
]

Symbol_.prototype.applyMask = function (mask) {
    for (var y = 0; y < this.size; y++) {
        for (var x = 0; x < this.size; x++) {
            if (!this.reserved[y][x] && MASKS[mask](x, y)) {
                this.modules[y][x] ^= 1
            }
        }
    }
}

// The four penalty rules, so a mask can be chosen rather than assumed. Not
// covered by the fixtures — those pin a mask so the comparison is exact — and
// it does not need to be: any of the eight masks produces a symbol that
// scans, and this only decides which one is easiest for a camera.
Symbol_.prototype.penalty = function () {
    var n = this.size
    var score = 0

    // 1. runs of five or more
    for (var y = 0; y < n; y++) {
        for (var pass = 0; pass < 2; pass++) {
            var run = 1
            for (var i = 1; i < n; i++) {
                var a = pass === 0 ? this.modules[y][i] : this.modules[i][y]
                var b = pass === 0 ? this.modules[y][i - 1] : this.modules[i - 1][y]
                if (a === b) {
                    run++
                    if (run === 5) score += 3
                    else if (run > 5) score += 1
                } else {
                    run = 1
                }
            }
        }
    }
    // 2. two-by-two blocks of one colour
    for (var y = 0; y < n - 1; y++) {
        for (var x = 0; x < n - 1; x++) {
            var c = this.modules[y][x]
            if (c === this.modules[y][x + 1] && c === this.modules[y + 1][x] &&
                c === this.modules[y + 1][x + 1]) score += 3
        }
    }
    // 3. the finder-like 1:1:3:1:1 pattern with four light modules beside it
    var finder = [1, 0, 1, 1, 1, 0, 1]
    for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
            for (var pass = 0; pass < 2; pass++) {
                var hit = true
                for (var k = 0; k < 7 && hit; k++) {
                    var xx = pass === 0 ? x + k : x
                    var yy = pass === 0 ? y : y + k
                    if (xx >= n || yy >= n || this.modules[yy][xx] !== finder[k]) hit = false
                }
                if (!hit) continue
                var before = true, after = true
                for (var k = 1; k <= 4; k++) {
                    var bx = pass === 0 ? x - k : x
                    var by = pass === 0 ? y : y - k
                    if (bx < 0 || by < 0 || this.modules[by][bx] !== 0) before = false
                    var ax = pass === 0 ? x + 6 + k : x
                    var ay = pass === 0 ? y : y + 6 + k
                    if (ax >= n || ay >= n || this.modules[ay][ax] !== 0) after = false
                }
                if (before || after) score += 40
            }
        }
    }
    // 4. how far the dark proportion is from half
    var dark = 0
    for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) dark += this.modules[y][x]
    var percent = Math.abs(dark * 100 - n * n * 50)
    score += Math.floor(percent / (n * n * 5)) * 10
    return score
}

// ── the one entry point ─────────────────────────────────────────────────────
//
//   encode("apex-remote:…")                       smallest version, best mask
//   encode(text, { level: "m", version: 7, mask: 3 })
//
// Returns { version, size, level, mask, modules } where `modules` is an array
// of `size` rows of `size` numbers, 1 for dark, top row first, with no quiet
// zone. A caller that draws it owes it four modules of light on every side.
function encode(text, options) {
    options = options || {}
    var level = options.level || "l"
    if (LEVELS.indexOf(level) < 0) throw new Error("unknown error correction level " + level)

    var bytes = toBytes(text)
    var version = options.version || smallestVersion(bytes, level)
    if (!version) throw new Error("no QR version holds " + bytes.length + " bytes at level " + level)
    if (dataCodewords(version, level) * 8 <
        4 + (version <= 9 ? 8 : 16) + bytes.length * 8) {
        throw new Error("version " + version + " does not hold " + bytes.length + " bytes")
    }

    var data = interleave(padded(segmentBits(bytes, version), version, level), version, level)

    function build(mask) {
        var s = new Symbol_(version)
        s.functionPatterns()
        s.codewords(data)
        s.applyMask(mask)
        s.formatBits(mask, level)
        return s
    }

    var mask = options.mask
    var symbol
    if (mask === undefined || mask === null) {
        var best = Infinity
        for (var m = 0; m < 8; m++) {
            var candidate = build(m)
            var p = candidate.penalty()
            if (p < best) { best = p; mask = m; symbol = candidate }
        }
    } else {
        if (!(mask >= 0 && mask <= 7)) throw new Error("mask must be 0..7")
        symbol = build(mask)
    }

    return {
        version: version,
        size: symbol.size,
        level: level,
        mask: mask,
        modules: symbol.modules
    }
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
//
// `toBytes`, `segmentBits` and `padded` are internals, exported so qr-test.js
// can assert §7.4.10's pad codewords against the specification directly rather
// than only through a fixture comparison — the fixtures come from an encoder
// that gets that clause wrong, so a test that could only see them could not
// tell a correct pad run from segno's. Nothing outside the test uses them.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        encode: encode,
        size: size,
        dataCodewords: dataCodewords,
        alignmentPositions: alignmentPositions,
        LEVELS: LEVELS,
        toBytes: toBytes,
        segmentBits: segmentBits,
        padded: padded
    }
