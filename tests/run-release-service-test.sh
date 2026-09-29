#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-release-service-test.sh — after an update, the Shell opens that release's
# page on rimeos.com once (src/services/ReleaseService.qml + release.js).
#
#     ./tests/run-release-service-test.sh
#
# The REAL service, in the private headless compositor (tests/lib/headless.sh),
# with everything it reaches outside itself replaced by a recorder on PATH:
#   curl        answers $STUB_CODE for the page probe
#   rpm-ostree  says whether a deployment to roll back to exists ($STUB_ROLLBACK)
#   notify-send records its arguments and "clicks" $STUB_ACTION
#   the opener  (RIME_RELEASE_OPENER) records the URL it was handed
# and one state file carried from run to run, as a user's is across boots.
# release-test.js covers every decision; this covers that the service reads
# the image's file, probes before it opens, opens detached through the opener,
# remembers, never opens twice, and falls back to a notification.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell
headless_begin
staged="$root/.release-service-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM
headless_start labwc 1280x800 || exit 0
cp "$here/release-service-test.qml" "$staged"

W="$HEADLESS_W/rel"; mkdir -p "$W"
B="$HEADLESS_W/bin"   # headless.sh put this first on PATH
# Its stubs are SYMLINKS to one shared _stub: writing over one would rewrite
# every stubbed command. Remove before writing.
rm -f "$B/curl" "$B/rpm-ostree" "$B/notify-send" "$B/xdg-open"
cat > "$B/curl" <<'EOF'
#!/bin/sh
# The probe's -w "%{http_code} %{url_effective}": the code, and where it
# landed ($STUB_LANDED, else the URL asked for — the last argument).
for a; do last="$a"; done
printf '%s %s' "${STUB_CODE:-200}" "${STUB_LANDED:-$last}"
EOF
cat > "$B/rpm-ostree" <<'EOF'
#!/bin/sh
if [ "${STUB_ROLLBACK:-0}" = 1 ]; then
  echo '{"deployments":[{"booted":true,"staged":false},{"booted":false,"staged":false}]}'
else
  echo '{"deployments":[{"booted":true,"staged":false},{"booted":false,"staged":true}]}'
fi
EOF
cat > "$B/notify-send" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$W/notify.log"
printf '%s\n' "\${STUB_ACTION:-}"
EOF
cat > "$W/opener" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$W/opened.log"
EOF
chmod +x "$B/curl" "$B/rpm-ostree" "$B/notify-send" "$W/opener"

state="$HOME/.local/state/rime/releases.json"
settings="$HOME/.config/rime-shell/src/user_data/settings.json"
release() { printf '{"schema":1,"id":"%s","version":"%s","notes":"https://rimeos.com/updates/%s"}\n' "$1" "$1" "$1" > "$W/release.json"; }

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
opened() { cat "$W/opened.log" 2>/dev/null; }
notified() { cat "$W/notify.log" 2>/dev/null; }

run() {   # run — one login: start the service, wait for its answer
    : > "$W/opened.log"; : > "$W/notify.log"
    RESULT="$(RIME_RELEASE_JSON="$W/release.json" RIME_RELEASE_OPENER="${OPENER:-$W/opener}" RIME_RELEASE_DELAY_MS=100 \
              timeout 40 quickshell -p "$staged" 2>&1 | sed -n 's/.*RESULT //p' | tail -1)"
    sleep 0.5   # the detached opener (setsid -f) writes after the shell has gone
}
st() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], ""))' "$state" "$1" 2>/dev/null; }

echo "── a first install ──"
release 2026.09.29; rm -f "$state"; STUB_ROLLBACK=0 STUB_CODE=200 run
case "$RESULT" in record*) ok "no state and no deployment to roll back to: recorded ($RESULT)";; *) bad "first install: $RESULT";; esac
[ -z "$(opened)" ] && ok "…and nothing was opened" || bad "a first install opened $(opened)"
[ "$(st lastOpenedNotes)" = 2026.09.29 ] && ok "…and it is remembered as seen" || bad "state after first install: $(cat "$state" 2>/dev/null)"

echo "── the first update to an image that has release.json ──"
rm -f "$state"; STUB_ROLLBACK=1 STUB_CODE=404 run
case "$RESULT" in pending*) ok "the page does not answer yet: held pending";; *) bad "unanswered page: $RESULT";; esac
[ -z "$(opened)" ] && ok "…nothing opened on a 404" || bad "opened a missing page: $(opened)"
[ "$(st pending)" = 2026.09.29 ] && ok "…and the pending release is saved" || bad "state: $(cat "$state" 2>/dev/null)"
STUB_ROLLBACK=1 STUB_CODE=200 STUB_LANDED=https://rimeos.com/updates/2026.09.28.4 run
[ -z "$(opened)" ] && [ "$(st pending)" = 2026.09.29 ] \
    && ok "a 200 that landed on ANOTHER page (a redirect to latest) is not this page: still pending" \
    || bad "a redirect elsewhere counted as the page: opened '$(opened)', result $RESULT"
STUB_ROLLBACK=1 STUB_CODE=200 run
[ "$(opened)" = https://rimeos.com/updates/2026.09.29 ] && ok "the next start, the page answers: opened once, through the opener" \
    || bad "after the page appeared: opened '$(opened)', result $RESULT"
[ "$(st lastOpenedNotes)" = 2026.09.29 ] && [ -z "$(st pending)" ] && ok "…marked seen, nothing pending" || bad "state: $(cat "$state")"
STUB_ROLLBACK=1 STUB_CODE=200 run
[ -z "$(opened)" ] && ok "the next start of the same release opens nothing" || bad "opened again: $(opened)"

echo "── a forward update ──"
release 2026.09.30; STUB_ROLLBACK=1 STUB_CODE=200 run
[ "$(opened)" = "https://rimeos.com/updates/2026.09.30?from=2026.09.29" ] && ok "the new page, ?from= the release before it" \
    || bad "forward update opened '$(opened)'"

echo "── a rollback ──"
release 2026.09.29; STUB_ROLLBACK=1 STUB_CODE=200 run
case "$RESULT" in rollback*) ok "booting the older release is a rollback";; *) bad "rollback: $RESULT";; esac
[ -z "$(opened)" ] && ok "…no page" || bad "a rollback opened $(opened)"
grep -q "Rime rolled back" <<<"$(notified)" && ok "…a small notice instead" || bad "rollback notice: $(notified)"

echo "── notes turned off ──"
mkdir -p "$(dirname "$settings")"; printf '{"openReleaseNotes": false}' > "$settings"
release 2026.10.01; STUB_ROLLBACK=1 STUB_CODE=200 STUB_ACTION="" run
case "$RESULT" in notify*) ok "with the setting off: a notification, not the browser";; *) bad "setting off: $RESULT";; esac
[ -z "$(opened)" ] && ok "…nothing opened unasked" || bad "opened with the setting off: $(opened)"
grep -q "See what changed" <<<"$(notified)" && ok "…the notification offers the page" || bad "notification: $(notified)"
release 2026.10.02; STUB_ROLLBACK=1 STUB_CODE=200 STUB_ACTION=open run
[ "$(opened)" = "https://rimeos.com/updates/2026.10.02?from=2026.10.01" ] && grep -q "See what changed" <<<"$(notified)" \
    && ok "…and choosing \"See what changed\" opens it" \
    || bad "the notification's action opened '$(opened)' (notified: $(notified))"
rm -f "$settings"

echo "── no rime-open-browser: xdg-open instead ──"
# headless.sh stubs xdg-open already (nothing here may reach a real browser);
# this one records what it was handed.
cat > "$B/xdg-open" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$W/xdg.log"
EOF
chmod +x "$B/xdg-open"; : > "$W/xdg.log"
release 2026.10.03; OPENER=/nonexistent STUB_ROLLBACK=1 STUB_CODE=200 STUB_ACTION="" run
[ "$(cat "$W/xdg.log")" = "https://rimeos.com/updates/2026.10.03?from=2026.10.02" ] \
    && ok "no opener at its path: xdg-open gets the page" || bad "fallback opener got '$(cat "$W/xdg.log")', result $RESULT"

echo "── a dev image ──"
printf '{"schema":1,"id":"dev","version":"dev","notes":""}\n' > "$W/release.json"; STUB_ROLLBACK=1 STUB_CODE=200 run
[ -z "$(opened)" ] && [ -z "$(notified)" ] && ok "a dev image (no notes URL) does nothing" || bad "dev image: $(opened) $(notified)"

echo
echo "release-service: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
