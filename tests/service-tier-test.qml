import Quickshell
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// ─────────────────────────────────────────────────────────────────────────────
// Behavioural test for the refcounted service tier.
//
// Run with a Wayland session available:
//     quickshell -p tests/service-tier-test.qml
// Exit status 0 = all assertions passed, 1 = at least one failed.
//
// What it proves, on real /proc and /sys:
//   1. Every telemetry service starts completely idle (refCount 0, no polling).
//   2. Acquiring a ServiceRef starts it and real data arrives.
//   3. Releasing the ref stops it — the value stops advancing.
//   4. ServiceRef accounting is drift-free across toggles, service swaps and
//      destruction, which is the property the old `active:` bindings lacked.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0
    property int phase: 0

    // Snapshots taken between phases.
    property var _origPinned: []
    property var _origHistory: ({})
    property bool _origNexusOpen: false
    property string _origNexusPage: ""
    property bool _origVpnActive: false
    property bool _origVpnConnecting: false
    property string _origVpnName: ""
    property real cpuAfterRef: -1
    property string memAfterRef: ""
    property int cpuTicksWhileReleased: -1

    function check(name, cond) {
        if (cond) {
            root.passed++;
            console.log("  PASS  " + name);
        } else {
            root.failed++;
            console.log("  FAIL  " + name);
        }
    }

    // Holder we can activate/deactivate on demand.
    property bool wantCpu: false
    property bool wantMem: false

    ServiceRef {
        service: CpuService
        active: root.wantCpu
    }

    ServiceRef {
        service: MemService
        active: root.wantMem
    }

    // ── LazyPopup first-open delivery ─────────────────────────────────────────
    // Regression guard. A lazily built popup is created BY the open transition,
    // so it cannot be listening for the signal that opened it: gating on that
    // signal alone left the network, notification and clipboard popups unmapped
    // until they were toggled a second time. LazyPopup must hand the state to
    // the popup it just built. The popup smoke test cannot catch this — a window
    // that never maps still exits zero and logs no error.
    property bool probeWanted: false

    LazyPopup {
        id: lazyProbe
        wanted: root.probeWanted

        QtObject {
            property int applied: 0
            function applyOpenState() { applied++ }
        }
    }

    // ── Notification toast: one notification, one toast ───────────────────────
    // The toast window can be built BY the notification it is meant to show, so
    // the service's signal is then a SECOND delivery of the same object. That
    // showed the same notification twice, five seconds apart.
    PanelWindow {
        id: toastAnchor
        visible: false
        implicitWidth:  420
        implicitHeight: 40
    }

    component FakeNote: QtObject {
        property bool tracked: true
        property string appName: "Probe"
        property string summary: "probe"
        property string body: ""
        property string image: ""
        property string appIcon: ""
        property var actions: []
    }

    readonly property FakeNote noteA: FakeNote {}
    readonly property FakeNote noteB: FakeNote {}

    NotificationToast {
        id: toastProbe
        anchorWindow: toastAnchor
    }

    // A ref we destroy outright, to prove Component.onDestruction releases.
    property Component throwawayComp: Component {
        ServiceRef {
            service: CpuService
            active: true
        }
    }
    property var throwaway: null

    Timer {
        interval: 700
        running: true
        repeat: true
        onTriggered: {
            root.phase++;
            switch (root.phase) {
            case 1:
                console.log("[1] everything idle before any consumer");
                root.check("CpuService starts at refCount 0", CpuService.refCount === 0);
                root.check("MemService starts at refCount 0", MemService.refCount === 0);
                root.check("NetService starts at refCount 0", NetService.refCount === 0);
                root.check("DiskService starts at refCount 0", DiskService.refCount === 0);
                root.check("GpuService starts at refCount 0", GpuService.refCount === 0);
                root.check("CpuFreqService starts at refCount 0", CpuFreqService.refCount === 0);
                root.check("PowerProfileService starts at refCount 0", PowerProfileService.refCount === 0);
                root.check("Time seconds clock starts disabled", Time.secondsEnabled === false);
                // A FileView with a `path` performs exactly ONE read when it is
                // constructed, which is why a freshly opened panel shows a real
                // value immediately instead of "—". That single read is free;
                // what must not happen is a repeating read with no consumer, and
                // phase [3] below is what proves that.
                root.check("CpuService is not polling yet", CpuService.poll.running === false);
                root.check("MemService is not polling yet", MemService.poll.running === false);
                root.check("NetService is not polling yet", NetService.poll.running === false);
                root.check("DiskService is not polling yet", DiskService.poll.running === false);
                root.check("CpuFreqService is not polling yet", CpuFreqService.poll.running === false);
                root.check("CpuFreqService daemon probe is not polling yet", CpuFreqService.daemonPoll.running === false);
                root.check("PowerProfileService is not polling yet", PowerProfileService.poll.running === false);
                root.check("GpuService is not polling yet", GpuService.poll.running === false);
                root.check("GpuService has not even enumerated yet", GpuService.gpus.length === 0);
                break;

            case 2:
                console.log("[2] acquire refs");
                root.wantCpu = true;
                root.wantMem = true;
                break;

            case 3:
                root.check("CpuService refCount is 1", CpuService.refCount === 1);
                root.check("MemService refCount is 1", MemService.refCount === 1);
                // /proc/meminfo always yields a total on a real machine.
                root.check("MemService read /proc/meminfo via FileView", MemService.totalGb > 0);
                root.check("MemService formatted a used value", MemService.usedStr !== "—");
                root.memAfterRef = MemService.usedStr;
                root.cpuAfterRef = CpuService.usagePercent;
                break;

            case 4:
                console.log("[3] release refs; values must freeze");
                root.wantCpu = false;
                root.wantMem = false;
                root.check("CpuService back to refCount 0", CpuService.refCount === 0);
                root.check("MemService back to refCount 0", MemService.refCount === 0);
                root.check("CpuService timer stopped", CpuService.poll.running === false);
                root.check("MemService timer stopped", MemService.poll.running === false);
                root.cpuTicksWhileReleased = CpuService.usagePercent;
                break;

            case 5:
                // Nothing should have updated it while unreferenced.
                root.check("CpuService stopped polling once released", CpuService.usagePercent === root.cpuTicksWhileReleased);
                break;

            case 6:
                console.log("[4] destruction releases the ref");
                root.throwaway = root.throwawayComp.createObject(root);
                root.check("transient ref took the count to 1", CpuService.refCount === 1);
                break;

            case 7:
                root.throwaway.destroy();
                root.throwaway = null;
                break;

            case 8:
                root.check("destroying the ref returned the count to 0", CpuService.refCount === 0);
                break;

            case 9:
                console.log("[5] double refs count independently");
                root.wantCpu = true;
                root.throwaway = root.throwawayComp.createObject(root);
                root.check("two independent refs give refCount 2", CpuService.refCount === 2);
                break;

            case 10:
                root.throwaway.destroy();
                root.throwaway = null;
                break;

            case 11:
                root.check("one ref left after destroying the other", CpuService.refCount === 1);
                root.wantCpu = false;
                root.check("last release returns to 0", CpuService.refCount === 0);
                root.check("no negative drift", CpuService.refCount >= 0);
                break;

            case 12:
                // ── DDC parsing ──────────────────────────────────────────
                // Cannot be exercised on a machine with only an internal
                // panel, so it is tested against captured ddcutil output.
                console.log("[6] ddcutil output parsing");

                const detect = "Display 1\n" + "   I2C bus:  /dev/i2c-5\n" + "   DRM connector: card1-DP-1\n" + "   Monitor: DEL:DELL U2723QE:ABC123\n" + "\n" + "Display 2\n" + "   I2C bus:  /dev/i2c-8\n" + "   DRM connector: card1-HDMI-A-1\n" + "   Monitor: GSM:LG HDR 4K:XYZ\n" + "\n" + "Invalid display\n" + "   I2C bus:  /dev/i2c-9\n" + "   Monitor: junk\n";

                const mons = BrightnessService.parseDdcDetect(detect);
                root.check("two DDC displays parsed", mons.length === 2);
                root.check("first bus is 5", mons.length > 0 && mons[0].bus === "5");
                // The card prefix must be stripped or the name never matches
                // ShellScreen.name and per-monitor routing silently fails.
                root.check("card prefix stripped from connector", mons.length > 0 && mons[0].connector === "DP-1");
                root.check("second connector is HDMI-A-1", mons.length > 1 && mons[1].connector === "HDMI-A-1");
                root.check("an 'Invalid display' block is skipped", mons.every(m => m.bus !== "9"));

                root.check("no displays parsed from empty output", BrightnessService.parseDdcDetect("").length === 0);
                root.check("ddcutil-absent output yields nothing", BrightnessService.parseDdcDetect("\n").length === 0);

                root.check("getvcp 50/100 is 0.5", BrightnessService.parseDdcGetvcp("VCP 10 C 50 100") === 0.5);
                root.check("getvcp 0/100 is 0", BrightnessService.parseDdcGetvcp("VCP 10 C 0 100") === 0);
                root.check("getvcp handles a non-100 maximum", BrightnessService.parseDdcGetvcp("VCP 10 C 32 64") === 0.5);
                root.check("garbage getvcp is rejected", BrightnessService.parseDdcGetvcp("nonsense") === -1);
                root.check("empty getvcp is rejected", BrightnessService.parseDdcGetvcp("") === -1);
                root.check("a zero maximum is rejected, not divided by", BrightnessService.parseDdcGetvcp("VCP 10 C 5 0") === -1);
                break;

            case 13:
                console.log("[7] launcher pinning and frecency");

                // Snapshot and restore: this singleton persists to the user's
                // real launcher.json.
                root._origPinned = LauncherState.pinned;
                root._origHistory = LauncherState.history;

                LauncherState.pinned = [];
                LauncherState.history = ({});

                root.check("nothing is pinned initially", !LauncherState.isPinned("firefox.desktop"));
                LauncherState.togglePin("firefox.desktop");
                root.check("pin sticks", LauncherState.isPinned("firefox.desktop"));
                LauncherState.togglePin("firefox.desktop");
                root.check("pin toggles off", !LauncherState.isPinned("firefox.desktop"));
                LauncherState.togglePin("");
                root.check("an empty id is ignored", LauncherState.pinned.length === 0);

                // Pin order is preserved so a user can arrange them.
                LauncherState.togglePin("a.desktop");
                LauncherState.togglePin("b.desktop");
                root.check("pin order is insertion order", LauncherState.pinned[0] === "a.desktop" && LauncherState.pinned[1] === "b.desktop");

                // Frecency: many launches long ago must still outrank a single
                // recent one, which is the entire reason this is not an MRU list.
                const now = Date.now();
                LauncherState.history = {
                    "heavy.desktop": { "count": 60, "last": now - 3 * 86400000 },
                    "oneoff.desktop": { "count": 1, "last": now - 60000 },
                    "stale.desktop": { "count": 40, "last": now - 400 * 86400000 }
                };

                root.check("a heavily used app outranks a single recent launch", LauncherState.score("heavy.desktop") > LauncherState.score("oneoff.desktop"));
                root.check("a year-old app decays below a fresh one-off", LauncherState.score("stale.desktop") < LauncherState.score("oneoff.desktop"));
                root.check("an unknown id scores zero", LauncherState.score("nope.desktop") === 0);

                const top = LauncherState.topRecent(2);
                root.check("topRecent honours the limit", top.length === 2);
                root.check("topRecent is best-first", top[0] === "heavy.desktop");

                // Decay must be monotonic in age at equal counts.
                LauncherState.history = {
                    "x": { "count": 5, "last": now - 1 * 86400000 },
                    "y": { "count": 5, "last": now - 30 * 86400000 }
                };
                root.check("at equal use, older ranks lower", LauncherState.score("x") > LauncherState.score("y"));

                LauncherState.clearHistory();
                root.check("clearHistory empties it", LauncherState.topRecent(5).length === 0);
                break;

            case 14:
                LauncherState.pinned = root._origPinned;
                LauncherState.history = root._origHistory;
                root.check("launcher state restored", LauncherState.pinned === root._origPinned);
                break;

            case 15:
                console.log("[8] settings page registry (shared by the dashboard tab and Nexus)");

                root.check("the registry is not empty", PageRegistry.pages.length > 0);
                root.check("firstId names a real page", PageRegistry.has(PageRegistry.firstId));
                root.check("an unknown id is not claimed", !PageRegistry.has("nope"));
                root.check("pageFor returns null for an unknown id", PageRegistry.pageFor("nope") === null);

                // Every page must be fully declared: a missing component means a
                // blank pane, and a missing title means a blank nav row. Both
                // would only show up by clicking every entry by hand.
                let wellFormed = true;
                let ids = ({});
                let dupes = false;
                for (const p of PageRegistry.pages) {
                    if (!p.id || !p.title || !p.icon || !p.component)
                        wellFormed = false;
                    if (typeof p.needsScreen !== "boolean")
                        wellFormed = false;
                    if (ids[p.id])
                        dupes = true;
                    ids[p.id] = true;
                }
                root.check("every page declares id/title/icon/component/needsScreen", wellFormed);
                root.check("page ids are unique", !dupes);

                // Data & Storage holds ServiceRefs, so it must be flagged or its
                // pollers would never be told to stop.
                root.check("the telemetry page is flagged needsScreen", PageRegistry.pageFor("data").needsScreen === true);

                // ── Nexus state machine ──────────────────────────────────
                root._origNexusOpen = NexusState.open;
                root._origNexusPage = NexusState.page;

                NexusState.close();
                root.check("starts closed", NexusState.open === false);

                NexusState.openAt("keybinds", "TEST-1");
                root.check("openAt opens", NexusState.open === true);
                root.check("openAt selects the page", NexusState.page === "keybinds");
                root.check("openAt records the screen", NexusState.screenName === "TEST-1");

                // Toggling to a DIFFERENT page must switch, not close: a keybind
                // for "settings at Keybinds" that closed the window because you
                // happened to be on Appearance would be useless.
                NexusState.toggle("misc", "TEST-1");
                root.check("toggle to another page switches instead of closing", NexusState.open === true && NexusState.page === "misc");

                // Toggling the page you are already on closes.
                NexusState.toggle("misc", "TEST-1");
                root.check("toggle on the current page closes", NexusState.open === false);

                // A bare toggle is the single-keybind case.
                NexusState.toggle("", "TEST-1");
                root.check("bare toggle opens", NexusState.open === true);
                NexusState.toggle("", "TEST-1");
                root.check("bare toggle closes again", NexusState.open === false);

                // An unknown page must not move the selection.
                NexusState.openAt("appearance", "TEST-1");
                NexusState.openAt("nonsense", "TEST-1");
                root.check("an unknown page leaves the selection alone", NexusState.page === "appearance");
                break;

            case 16:
                NexusState.open = root._origNexusOpen;
                NexusState.page = root._origNexusPage;
                root.check("nexus state restored", NexusState.page === root._origNexusPage);
                break;

            case 17:
                console.log("[9] VPN probe/action sequencing");
                root._origVpnActive = ShellState.vpnActive;
                root._origVpnConnecting = ShellState.vpnConnecting;
                root._origVpnName = ShellState.vpnName;

                const staleGeneration = ShellState._vpnGeneration;
                ShellState.updateVpnState(false, true, "test-vpn");
                ShellState.updateVpnState(true, false, "test-vpn");

                root.check("an action advances the VPN generation",
                    ShellState._vpnGeneration > staleGeneration);
                root.check("a pre-action probe result is discarded",
                    !ShellState.applyVpnProbeResult("", staleGeneration));
                root.check("a stale probe cannot clear the completed action",
                    ShellState.vpnActive && ShellState.vpnName === "test-vpn");
                root.check("a current external VPN probe is applied",
                    ShellState.applyVpnProbeResult("external-vpn", ShellState._vpnGeneration)
                    && ShellState.vpnActive && ShellState.vpnName === "external-vpn");

                ShellState.updateVpnState(root._origVpnActive,
                    root._origVpnConnecting, root._origVpnName);
                break;

            case 18:
                console.log("[10] LazyPopup hands the open state to what it builds");
                root.check("nothing is built while unwanted", lazyProbe.item === null);
                root.probeWanted = true;
                break;

            case 19:
                root.check("the popup is built once wanted", lazyProbe.item !== null);
                root.check("applyOpenState ran for the transition that built it",
                    lazyProbe.item !== null && lazyProbe.item.applied === 1);
                // The latch must not re-fire the open state on later toggles.
                root.probeWanted = false;
                root.check("the built popup is retained, not unloaded",
                    lazyProbe.item !== null);
                root.check("applyOpenState did not run again",
                    lazyProbe.item !== null && lazyProbe.item.applied === 1);
                break;

            case 20:
                console.log("[11] one notification produces exactly one toast");
                NotificationService.lastToast = root.noteA;
                toastProbe.applyOpenState();
                root.check("the toast claims the notification that built it",
                    toastProbe.current === root.noteA);
                // The same object arriving again is the second delivery.
                NotificationService.notificationAdded(root.noteA);
                root.check("the claimed notification is not queued again",
                    toastProbe.queue.length === 0);
                // A genuinely new one must still queue behind it.
                NotificationService.notificationAdded(root.noteB);
                root.check("a different notification still queues",
                    toastProbe.queue.length === 1);
                // And it must not be double-claimed once it is queued.
                toastProbe.applyOpenState();
                NotificationService.lastToast = root.noteB;
                toastProbe.applyOpenState();
                root.check("a queued notification is not claimed twice",
                    toastProbe.queue.length === 1 && toastProbe.current === root.noteA);
                NotificationService.lastToast = null;
                break;

            default:
                console.log("");
                console.log("passed=" + root.passed + " failed=" + root.failed);
                Qt.exit(root.failed === 0 ? 0 : 1);
            }
        }
    }
}
