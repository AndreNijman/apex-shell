import QtQuick
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Pair a device  (roadmap P1-051, criterion 1)
//
// "Desktop can display a QR code / short pairing flow from APEX Shell."
//
// ── Why this page is where the QR lives ─────────────────────────────────────
//
// `apex remote pair` deliberately refuses to draw one in a terminal, and says
// why in its own source: "no encoder is vendored, and a wrong QR is worse than
// none — a phone scans it, fails, and the person concludes their camera is
// broken." It prints the payload and points here. This is the here.
//
// ── A code is minted, not read ──────────────────────────────────────────────
//
// Every other settings page of this shape asks questions on a timer. This one
// cannot: `apex remote pair` mints a ONE-TIME token and arms the daemon for
// the next device presenting it. Minting on a sweep would burn a token every
// interval, and each new one invalidates the code the person is at that moment
// holding their phone up to.
//
// So `ensureCode()` on becoming visible, and the button, and nothing else.
// Coming back to the page while a code is still good shows the same code
// rather than replacing it. An offer expiring is deliberately NOT a third
// trigger — see the service's header on why arming this machine every three
// minutes for a page somebody walked away from is the wrong trade.
// tests/run-remote-pairing-page-test.sh asserts the whole rule against the
// stub's call log: zero `pair` calls before the page is shown, exactly one
// after, still one after leaving and returning, two after asking.
//
// ── No code is a first-class state, not an empty frame ──────────────────────
//
// When there is no offer the page says why, in the words the command used, and
// draws NOTHING where the code would be. Not a placeholder, not a greyed
// square, not a stale code with a note. A QR-shaped thing that is not a
// scannable current offer produces exactly the failure the feature is built to
// avoid, and "the code expired" and "the service is not running" are different
// problems a person has to be able to tell apart.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    lifecycle: "live"

    // Set by ShellConfig: "this page is genuinely on screen". Without it the
    // service sweeps for the whole life of the shell, and — worse here than
    // elsewhere — the page would mint a pairing code for somebody who never
    // opened it.
    property bool onScreen: false

    ServiceRef {
        service: RemotePairingService
        active: root.onScreen
    }

    // The one place a code is asked for. `ensureCode`, not `requestCode`:
    // returning to a page must not invalidate a code being scanned right now.
    //
    // Asked for on BOTH orderings, because there is no guaranteed one. Setting
    // `onScreen` fires this handler and separately re-evaluates the ServiceRef
    // binding above that raises the service's refCount, and QML does not say
    // which happens first. It reached here as a page that showed no code at
    // all: the handler ran while refCount was still zero, `requestCode` saw an
    // inactive service and returned, and nothing asked again.
    //
    // Both paths land on `ensureCode`, which is idempotent while an offer is
    // live, so being called twice mints once.
    onOnScreenChanged: if (root.onScreen && RemotePairingService.active)
        RemotePairingService.ensureCode()

    Connections {
        target: RemotePairingService
        function onActiveChanged() {
            if (RemotePairingService.active && root.onScreen)
                RemotePairingService.ensureCode()
        }
    }

    // ── The code ─────────────────────────────────────────────────────────────
    CfgSection {
        title: "Scan this with APEX Remote"
        first: true

        // The symbol itself, on its own fixed-contrast ground. The quiet zone
        // is QrCode's, not this container's — see that file on why four
        // modules of light are part of the symbol rather than padding.
        Rectangle {
            x: theme.px(10)
            width: parent.width - theme.px(20)
            height: theme.px(260)
            radius: theme.px(10)
            color: Theme.fixedLight
            visible: RemotePairingService.offerLive

            QrCode {
                id: code
                anchors.centerIn: parent
                width: Math.min(parent.width - theme.px(24), theme.px(236))
                height: width
                payload: RemotePairingService.offerLive ? RemotePairingService.payload : ""
            }
        }

        // What the person is looking at, and how long it lasts.
        CfgRow {
            label: "Good for"
            description: "The code pairs exactly one device and then stops working. It carries this machine's public key, so the phone that scans it cannot be talked into trusting a different machine."
            visible: RemotePairingService.offerLive

            Text {
                text: RemotePairingService.countdown
                font.pixelSize: theme.fs(13)
                font.family: "JetBrains Mono"
                // The countdown is a fact, not a warning. It does not turn red
                // near zero: an expiring code is replaced by asking for a new
                // one, which is a button, not an emergency.
                color: Theme.text
            }
        }

        // ── No code, and why ─────────────────────────────────────────────────
        CfgRow {
            id: noCode
            label: "No pairing code"
            // The command's own words rather than a paraphrase. "apex remote
            // pair exited 1" is something a person can search for and a
            // developer can act on; "Something went wrong" is neither.
            description: RemotePairingService.pairError !== ""
                ? RemotePairingService.pairError
                : RemotePairingService.pairing
                    ? "Asking the service for one…"
                    : "The last code expired. Ask for a new one."
            visible: !RemotePairingService.offerLive
        }

        CfgRow {
            label: "New code"
            description: "Invalidates the one above, if there is one, and mints a fresh three-minute code."

            CfgButton {
                label: RemotePairingService.pairing ? "Asking…" : "New code"
                icon: "󰑐"
                enabled: !RemotePairingService.pairing
                onClicked: RemotePairingService.requestCode()
            }
        }
    }

    // ── What the code actually carries ───────────────────────────────────────
    // Said on the page rather than left to documentation, because a person is
    // about to point a camera at a key exchange and is entitled to know what
    // is in it.
    CfgSection {
        title: "What is in the code"

        CfgRow {
            label: "This machine's public key"
            description: "The phone pins it at pairing. Every later connection proves possession of the matching secret, so a machine that is not this one cannot answer for it — including the relay, which carries bytes it cannot read."
        }

        CfgRow {
            label: "Where to reach this machine"
            description: "The addresses this machine has on the local network, and the relay to meet at if none of them works. None of them is authenticated and none needs to be: reaching the wrong address produces a handshake that does not complete, not a connection to the wrong machine."
        }

        CfgRow {
            label: "Not your files, and not a password"
            description: "The code is a public key, a one-time token and a list of addresses. It is useless to anyone who scans it after the three minutes are up, or after one device has used it."
        }
    }
}
