import Quickshell
import QtQuick
import "./src/components"
import "./src/services"
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

            default:
                console.log("");
                console.log("passed=" + root.passed + " failed=" + root.failed);
                Qt.exit(root.failed === 0 ? 0 : 1);
            }
        }
    }
}
