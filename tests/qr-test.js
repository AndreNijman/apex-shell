#!/usr/bin/env node
// Tests the QR encoder the shell actually loads (src/services/qr.js), not a
// copy of it.
//
//   node tests/qr-test.js
//
// ── What this has to establish ───────────────────────────────────────────────
//
// P1-051's first criterion is a pairing code a phone can scan. `apex remote
// pair` refuses to draw one in the terminal and says why in its own source
// (apexd/apex/src/remote.rs, `qr_block`): "a wrong QR is worse than none — a
// phone scans it, fails, and the person concludes their camera is broken."
// So it is not enough for the output to look like a QR code, and "it renders"
// is not a test. Every module has to be the right module.
//
// ── The oracle, and the one place it is wrong ────────────────────────────────
//
// tests/fixtures/qr-vectors.json holds 36 matrices from segno 1.6.6, an
// independent implementation, with version, mode, mask and error level all
// pinned so each case has exactly one correct answer. Thirty-two are stock
// segno. Four are segno with a one-line correction, because segno 1.6.6
// appends a spurious 0x00 codeword where ISO/IEC 18004 §7.4.10 requires the
// pad codewords 11101100 / 00010001 — its own source quotes the clause and
// drops the condition in it. tests/fixtures/gen-qr-vectors.py's header is the
// full account, with segno's line reproduced.
//
// Correcting an oracle is the move that destroys an oracle, so three things
// here keep it honest:
//
//   * The generator DERIVES which cases the correction touched, by building
//     every case twice and diffing, and writes the names into `_iso_corrected`.
//     This file pins that list — see "the correction reached exactly the four
//     cases that carry padding" below. A correction that spread would fail
//     here, and if segno fixes the bug upstream the list empties and the same
//     assertion reds, which is the prompt to delete the patch.
//   * The padding rule is ALSO asserted directly against §7.4.10, from the
//     codewords rather than from a fixture — see "§7.4.10". Those assertions
//     would still hold if every fixture were deleted, and they are the ones
//     that distinguish a correct pad run from segno's.
//   * The 32 untouched cases fill their symbol to capacity and have no padding
//     at all, so the correction provably cannot reach them. They are compared
//     against an oracle this tree did not influence.
//
// The alignment-pattern table is pinned the same way, from ISO/IEC 18004
// Annex E rather than from the fixtures, because the general formula truncates
// where the obvious reading rounds up. The encoder shipped with `Math.ceil`
// there and every version from 7 up was wrong — the fixtures caught it, and
// the table below is what stops it coming back without a 2000-line diff to
// read.

"use strict";

const path = require("path");
const QR = require(path.join(__dirname, "..", "src", "services", "qr.js"));
const FIX = require(path.join(__dirname, "fixtures", "qr-vectors.json"));

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

function throws(name, fn) {
    let threw = false;
    try { fn(); } catch (e) { threw = true; }
    check(name, threw, true);
}

// Look a case up by name and insist there is exactly one. A lookup that
// returns the first match goes quiet when a fixture is renamed — the
// assertions that used it stop running instead of failing, and a suite with
// four fewer assertions still reports green.
function caseNamed(name) {
    const hits = FIX.cases.filter(c => c.name === name);
    if (hits.length !== 1) {
        failed++;
        console.error(`FAIL fixture lookup ${name}\n  got:  ${hits.length} matches\n  want: exactly 1`);
        return null;
    }
    return hits[0];
}

// ── the fixture file is the one this test was written against ────────────────
// Exact counts, not floors. A case that disappears has to red something.

check("the fixture carries 36 cases", FIX.cases.length, 36);
check("every case name is unique",
      new Set(FIX.cases.map(c => c.name)).size, 36);
check("all four error correction levels are covered",
      [...new Set(FIX.cases.map(c => c.error))].sort(), ["h", "l", "m", "q"]);
check("all eight masks are covered",
      [...new Set(FIX.cases.map(c => c.mask))].sort((a, b) => a - b),
      [0, 1, 2, 3, 4, 5, 6, 7]);
check("the smallest and largest symbols are both there",
      [Math.min(...FIX.cases.map(c => c.version)),
       Math.max(...FIX.cases.map(c => c.version))], [1, 40]);
check("every matrix is square and the size its version says",
      FIX.cases.filter(c => c.size === 4 * c.version + 17 &&
                            c.matrix.length === c.size &&
                            c.matrix.every(r => r.length === c.size)).length, 36);
check("every module is 0 or 1",
      FIX.cases.every(c => c.matrix.every(r => r.every(m => m === 0 || m === 1))), true);

// ── the correction reached exactly the four cases that carry padding ─────────
// `_iso_corrected` is computed by the generator, which builds every case with
// stock segno and again with §7.4.10 restored and diffs the two. Pinning the
// list here is what stops the correction quietly growing into cases it has no
// business touching, and what turns "segno fixed it upstream" into a failing
// test rather than a silent no-op.

check("the ISO correction touched exactly four cases",
      (FIX._iso_corrected || []).slice().sort(),
      ["offer-lan-only", "offer-with-relay", "v10-l-m0-short", "v4-l-m0-oneshort"].sort());
check("the corrected cases are the ones whose payload is short of capacity",
      (FIX._iso_corrected || []).every(n => {
          const c = caseNamed(n);
          if (!c) return false;
          const bits = 4 + (c.version <= 9 ? 8 : 16) + QR.toBytes(c.payload).length * 8;
          return bits < QR.dataCodewords(c.version, c.error) * 8;
      }), true);
check("every case the correction did NOT touch fills its symbol exactly",
      FIX.cases.filter(c => (FIX._iso_corrected || []).indexOf(c.name) < 0)
               .every(c => {
          // No room for even one pad codeword, so the padding path -- the only
          // thing the correction changes -- cannot run.
          const bits = 4 + (c.version <= 9 ? 8 : 16) + QR.toBytes(c.payload).length * 8;
          return QR.dataCodewords(c.version, c.error) * 8 - bits < 8;
      }), true);
check("the fixture says which encoder produced it",
      /^segno \d+\.\d+\.\d+,/.test(FIX._generated_by || ""), true);

// ── every module of every case ───────────────────────────────────────────────
// One assertion per case rather than one for all 36, so a failure names the
// version, level and mask that broke instead of saying "something differs".

for (const c of FIX.cases) {
    let got;
    try {
        got = QR.encode(c.payload, { level: c.error, version: c.version, mask: c.mask });
    } catch (e) {
        failed++;
        console.error(`FAIL ${c.name}: encode threw ${e.message}`);
        continue;
    }
    let differ = 0;
    let firstAt = null;
    for (let y = 0; y < c.size; y++) {
        for (let x = 0; x < c.size; x++) {
            if (got.modules[y][x] !== c.matrix[y][x]) {
                differ++;
                if (!firstAt) firstAt = [x, y];
            }
        }
    }
    check(`${c.name}: all ${c.size * c.size} modules match segno` +
          (firstAt ? ` (first difference at ${firstAt})` : ""),
          [got.size, differ], [c.size, 0]);
}

// ── ISO/IEC 18004 Annex E: the alignment pattern centres ─────────────────────
// Transcribed from the standard, not from the encoder and not from the
// fixtures. The general formula TRUNCATES; `Math.ceil` reads more naturally
// and is wrong for every version from 7 up, which is what shipped here first.
// Version 32 is the documented exception the formula does not produce.

const ALIGNMENT = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
    7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
    11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62],
    14: [6, 26, 46, 66], 15: [6, 26, 48, 70], 16: [6, 26, 50, 74],
    17: [6, 30, 54, 78], 18: [6, 30, 56, 82], 19: [6, 30, 58, 86],
    20: [6, 34, 62, 90],
    21: [6, 28, 50, 72, 94], 22: [6, 26, 50, 74, 98], 23: [6, 30, 54, 78, 102],
    24: [6, 28, 54, 80, 106], 25: [6, 32, 58, 84, 110], 26: [6, 30, 58, 86, 114],
    27: [6, 34, 62, 90, 118],
    28: [6, 26, 50, 74, 98, 122], 29: [6, 30, 54, 78, 102, 126],
    30: [6, 26, 52, 78, 104, 130], 31: [6, 30, 56, 82, 108, 134],
    32: [6, 34, 60, 86, 112, 138], 33: [6, 30, 58, 86, 114, 142],
    34: [6, 34, 62, 90, 118, 146],
    35: [6, 30, 54, 78, 102, 126, 150], 36: [6, 24, 50, 76, 102, 128, 154],
    37: [6, 28, 54, 80, 106, 132, 158], 38: [6, 32, 58, 84, 110, 136, 162],
    39: [6, 26, 54, 82, 110, 138, 166], 40: [6, 30, 58, 86, 114, 142, 170]
};

const wrongAlignment = [];
for (let v = 1; v <= 40; v++) {
    if (JSON.stringify(QR.alignmentPositions(v)) !== JSON.stringify(ALIGNMENT[v])) {
        wrongAlignment.push(v);
    }
}
check("every version's alignment centres match ISO/IEC 18004 Annex E",
      wrongAlignment, []);
check("version 32 is the exception the general formula gets wrong",
      QR.alignmentPositions(32), [6, 34, 60, 86, 112, 138]);

// ── §7.4.10: the pad codewords ───────────────────────────────────────────────
// Read off the codeword stream, so these hold with every fixture deleted.
// This is the clause segno 1.6.6 gets wrong, and the only assertions in this
// file that can tell a correct pad run from segno's.
//
// In byte mode the header is 4 mode bits plus an 8- or 16-bit count, so the
// stream is always 4 bits past a codeword boundary and the 4-bit terminator
// always lands it exactly on one. "Extend with 0 bits as necessary to reach a
// boundary" therefore always means "add none", and the very next codeword is
// the first pad codeword, 0xec. Appending a byte of zeros there instead is
// exactly segno's bug.

function codewordsFor(text, version, level) {
    return QR.padded(QR.segmentBits(QR.toBytes(text), version), version, level);
}

// v4-L holds 80 data codewords; 77 bytes of payload leaves room for exactly
// one pad codeword after the terminator.
const oneShort = codewordsFor("A".repeat(77), 4, "l");
check("a payload one codeword short fills the symbol's data capacity",
      oneShort.length, QR.dataCodewords(4, "l"));
check("the codeword before the pad carries the payload's tail and the terminator",
      oneShort[78], 0x10);
check("§7.4.10: the first pad codeword is 0xec, not a byte of zeros",
      oneShort[79], 0xec);

// A much shorter payload, so the alternation is visible rather than inferred.
const short = codewordsFor("short payload, plenty of padding after it", 10, "l");
check("a short payload still fills the data capacity",
      short.length, QR.dataCodewords(10, "l"));
check("§7.4.10: the pad run is 0xec and 0x11 alternating, starting at 0xec",
      short.slice(44, 52), [0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11]);
check("§7.4.10: no byte of zeros is inserted before the pad run",
      short.slice(43, 46), [0x40, 0xec, 0x11]);
check("§7.4.10: the pad run reaches the last data codeword",
      short[short.length - 1], short.length % 2 === 0 ? 0x11 : 0xec);
check("a payload that fills its symbol exactly gets no pad codewords at all",
      codewordsFor("A".repeat(78), 4, "l").slice(-1), [0x10]);

// ── the symbol's geometry and capacity ───────────────────────────────────────

check("a symbol is 4v+17 modules on a side",
      [QR.size(1), QR.size(7), QR.size(40)], [21, 45, 177]);
check("version 1's data capacity is the published one, at all four levels",
      QR.LEVELS.map(l => QR.dataCodewords(1, l)), [19, 16, 13, 9]);
check("version 40's data capacity is the published one, at all four levels",
      QR.LEVELS.map(l => QR.dataCodewords(40, l)), [2956, 2334, 1666, 1276]);
check("the four levels are l, m, q, h in that order", QR.LEVELS, ["l", "m", "q", "h"]);

// ── the entry point ──────────────────────────────────────────────────────────

const auto = QR.encode("apex-remote:hello");
// Version 1 at level l holds 19 data codewords -- 152 bits, of which 12 are
// the mode indicator and the count -- so 17 bytes fit and 18 do not. Asserting
// both sides of that boundary is what makes this about choosing a version
// rather than about one payload happening to land somewhere.
check("encode picks the smallest version that holds the payload",
      [QR.toBytes("apex-remote:hello").length, auto.version], [17, 1]);
check("one byte more than version 1 holds moves the symbol up a version",
      QR.encode("apex-remote:hello!").version, 2);
check("encode defaults to error correction level l", auto.level, "l");
check("encode picks a mask in range", auto.mask >= 0 && auto.mask <= 7, true);
check("encode reports the size its matrix actually is",
      [auto.size, auto.modules.length, auto.modules[0].length],
      [QR.size(auto.version), QR.size(auto.version), QR.size(auto.version)]);
check("mask selection is deterministic",
      QR.encode("apex-remote:hello").mask, auto.mask);
check("the matrix carries no quiet zone: the top-left module is the finder's",
      [auto.modules[0][0], auto.modules[0][7]], [1, 0]);

throws("an unknown error correction level is refused",
       () => QR.encode("x", { level: "z" }));
throws("a mask outside 0..7 is refused",
       () => QR.encode("x", { mask: 8 }));
throws("a payload too big for the version it was given is refused",
       () => QR.encode("A".repeat(100), { version: 1, level: "l" }));
throws("a payload too big for any version is refused",
       () => QR.encode("A".repeat(3000), { level: "h" }));

// ── the payload APEX actually produces ───────────────────────────────────────
// The two `offer-*` fixtures are apex_remote_core::pairing::PairingOffer's own
// field set, compact-JSON'd and base64url'd behind that crate's SCHEME. The
// version each lands on is what the pairing page will have to render, so it is
// pinned: a payload that quietly grew past a version boundary changes how
// dense the code on screen is, and is worth knowing about.

const lanOnly = caseNamed("offer-lan-only");
const withRelay = caseNamed("offer-with-relay");
check("a LAN-only pairing offer is a version 11 symbol",
      lanOnly && [lanOnly.version, lanOnly.size], [11, 61]);
check("a pairing offer naming a relay is a version 13 symbol",
      withRelay && [withRelay.version, withRelay.size], [13, 69]);
check("both pairing offers carry the scheme apex-remote-core declares",
      [lanOnly, withRelay].every(c => c && c.payload.startsWith("apex-remote:")), true);
check("encode chooses those versions on its own, without being told",
      [QR.encode(lanOnly.payload).version, QR.encode(withRelay.payload).version],
      [11, 13]);

// ── UTF-8 ────────────────────────────────────────────────────────────────────
// A pairing payload is ASCII by construction, but a machine name is not
// necessarily, and a QR code carrying mojibake pairs a phone with a machine
// whose name is wrong.

check("ascii is one byte per character", QR.toBytes("abc"), [97, 98, 99]);
check("a two-byte character encodes as two bytes", QR.toBytes("é"), [0xc3, 0xa9]);
check("a three-byte character encodes as three bytes",
      QR.toBytes("日"), [0xe6, 0x97, 0xa5]);
check("a surrogate pair encodes as one four-byte character",
      QR.toBytes("\u{1F600}"), [0xf0, 0x9f, 0x98, 0x80]);
check("a payload's byte length, not its character length, chooses the version",
      QR.encode("日".repeat(6), { level: "l" }).version,
      QR.encode("A".repeat(18), { level: "l" }).version);

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
