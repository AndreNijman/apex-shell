#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-remote-pairing-page-test.sh — the two APEX Remote pages, built by the
#  real engine and driven headlessly (roadmap P1-051, criteria 1, 3 and 5).
#
#  ── Why the `apex` here is a stub, and why that is not optional ─────────────
#
#  `apex remote pair` MINTS A ONE-TIME PAIRING TOKEN and arms the real daemon
#  to accept the next device that presents it. A suite that ran the real
#  command would arm the developer's own machine several times per run for a
#  phone nobody is holding, and `apex remote revoke` would take a real device's
#  access away. tests/lib/headless.sh already installs a stub `apex` on PATH
#  for this class of problem; this file replaces it with one that answers the
#  four `remote` verbs from fixtures and records its argv.
#
#  That is also the reason the service under test goes through the CLI instead
#  of opening apex-remoted's control socket: a socket client would walk
#  straight past the stub, and no PATH or HOME isolates a unix socket in
#  $XDG_RUNTIME_DIR. The stub is the isolation, so the CLI is the only way in.
#
#  ── Three phases, and the negative one is the important one ────────────────
#
#    pair-ok     the daemon answers; a scannable code is on screen
#    pair-fail   `apex remote pair` exits 1; there must be NO code on screen
#    devices     three paired devices, one revoked, one connected right now
#
#  `pair-fail` carries the assertion the whole feature turns on. `apex remote
#  pair` refuses to draw a QR in a terminal and says why in its own source: "a
#  wrong QR is worse than none — a phone scans it, fails, and the person
#  concludes their camera is broken". A page that drew a placeholder, a greyed
#  square, or a stale code when it had no offer would reintroduce exactly that,
#  and it would look fine in a screenshot. So that phase asserts a negative:
#  nothing in the built page holds a QR matrix at all.
#
#  ── Exact floors, not comfortable margins ───────────────────────────────────
#
#  Each phase is given the exact number of assertions it makes when green. The
#  colour-page suite records why: a paraphrase mutant once left a phase with 32
#  of its 36 assertions — four had VANISHED rather than failed — and a floor of
#  28 let it through. An assertion that stops running is a failure here,
#  whatever the reason.
#
#  Skips cleanly, exit 0, with no quickshell or no wlroots compositor.
#
#  Run from anywhere.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

# shellcheck source=/dev/null
. "$here/lib/headless.sh"

headless_require quickshell python3

W=""
staged="$root/.remote-pairing-page-test.qml"
cleanup() {
    rm -f "$staged"
    [[ -n "$W" ]] && rm -rf "$W"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin
W="$(mktemp -d)"
CALLS="$W/calls.log"

# ── the stub ────────────────────────────────────────────────────────────────
# Overwrites the one headless_begin installed. Every invocation is recorded
# before anything else happens, so an assertion about what the page ASKED FOR
# holds even when the answer is a failure.
cat > "$HEADLESS_W/bin/apex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$APEX_RP_CALLS"

if [[ "${1:-}" != "remote" ]]; then
    exit 0
fi

case "${2:-}" in
pair)
    if [[ "${APEX_RP_PAIR_FAIL:-0}" == "1" ]]; then
        echo "apex: the service is not running" >&2
        exit 1
    fi
    # apex_remote_core::pairing::PairingOffer's own field set, compact JSON,
    # base64url without padding, behind that crate's SCHEME -- the same shape
    # tests/fixtures/gen-qr-vectors.py builds its `offer-*` cases from. The
    # expiry is minted fresh, because the page refuses to show an offer whose
    # three minutes are up and a fixed one would go stale the day after it was
    # written.
    python3 - <<'PY'
import base64, json, os, time
key = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("=")
tok = base64.urlsafe_b64encode(bytes(range(32, 64))).decode().rstrip("=")
offer = {
    "v": 1, "machine": "l16", "key": key, "token": tok,
    "lan": ["192.168.1.20:7717"], "relay": None,
    "expires_ms": int(time.time() * 1000) + 180000,
}
body = json.dumps(offer, separators=(",", ":")).encode()
payload = "apex-remote:" + base64.urlsafe_b64encode(body).decode().rstrip("=")
# 275 bytes, which at error correction level m is a version 12 symbol, 65
# modules on a side. The driver asserts that number; if this offer ever
# changes shape, that assertion is what says so.
assert len(payload) == 275, len(payload)
print(payload)
PY
    # The sentences for the person go to stderr, as the real command does.
    # A parser that scraped stdout for prose would pass against a stub that
    # printed none, so the stub prints it.
    echo "" >&2
    echo "Scan this with APEX Remote. It is good for 180 seconds and pairs one device." >&2
    exit 0
    ;;
devices)
    # Three devices: one connected right now, one revoked, one that has never
    # completed a handshake. `#[serde(default)]` on the optional fields means
    # they are present as null rather than absent, which is the real shape.
    cat <<'JSON'
[
  {"id":"AAAAAQIDBAUGBwgJ","name":"Pixel 8","public_key":"AAAAAQIDBAUGBwgJCgsMDQ4P",
   "paired_ms":1789000000000,"last_seen_ms":1789155000000,"revoked_ms":null,
   "requires_user_verification":true,"last_path":"lan"},
  {"id":"BBBBAQIDBAUGBwgJ","name":"Old phone","public_key":"BBBBAQIDBAUGBwgJCgsMDQ4P",
   "paired_ms":1780000000000,"last_seen_ms":1781000000000,"revoked_ms":1789100000000,
   "requires_user_verification":false,"last_path":"relay"},
  {"id":"CCCCAQIDBAUGBwgJ","name":"Tablet","public_key":"CCCCAQIDBAUGBwgJCgsMDQ4P",
   "paired_ms":1789154000000,"last_seen_ms":null,"revoked_ms":null,
   "requires_user_verification":false,"last_path":null}
]
JSON
    exit 0
    ;;
status)
    # One connection open, naming the first device. The page must read
    # "connected" from here and not infer it from how recently a device was
    # seen -- those are different facts and the second one is not evidence.
    cat <<'JSON'
{"reply":"status","version":1,"key":"AAAA","machine":"l16",
 "lan":["192.168.1.20:7717"],"relay":null,"rendezvous":"abcd","paired":2,
 "offer_ms_left":null,
 "connections":[{"device":"AAAAAQIDBAUGBwgJ","path":"lan","rtt_ms":12,"since_ms":1789155000000}]}
JSON
    exit 0
    ;;
revoke)
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$HEADLESS_W/bin/apex"

# Quickshell refuses to import QML modules from outside the directory holding
# the entry point, so the suite is staged into the repository root.
cp "$here/remote-pairing-page-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

phase() {
    local name="$1" page="$2" want="$3" pairfail="${4:-0}"
    local log="$W/$name.log"
    : > "$CALLS"

    echo
    echo "── $name ────────────────────────────────────────────────"

    ( cd "$root" && env \
        APEX_RP_PHASE="$name" \
        APEX_RP_PAGE="$page" \
        APEX_RP_CALLS="$CALLS" \
        APEX_RP_PAIR_FAIL="$pairfail" \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) > "$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"
    grep -E "^(  PASS|  FAIL)" "$log" || true

    # A page that does not build prints a QML error and no assertions at all,
    # which without this reads as "0 of 0 passed".
    if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError" "$log"; then
        bad "the $name page built without QML errors"
        grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError" "$log" \
            | head -5 | sed 's/^/          /'
    else
        ok "the $name page built without QML errors"
    fi

    local summary got_pass got_fail
    summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
    if [[ -z "$summary" ]]; then
        bad "$name reported a result at all"
        tail -20 "$log" | sed 's/^/          /'
        return
    fi
    got_pass="${summary#passed=}"; got_pass="${got_pass%% *}"
    got_fail="${summary##*failed=}"

    if [[ "$got_fail" -eq 0 ]]; then
        ok "$name: no assertion failed"
    else
        bad "$name: $got_fail assertion(s) failed"
    fi

    # The exact green count, not a floor below it. An assertion that stops
    # running has to be a failure, or a paraphrase that deletes four of them
    # passes.
    if [[ "$got_pass" -eq "$want" ]]; then
        ok "$name made all $want of its assertions"
    else
        bad "$name made $got_pass assertions, expected exactly $want"
    fi
}

phase pair-ok    remote-pair    20 0
phase pair-fail  remote-pair     8 1
phase devices    remote-devices 22 0

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
