import QtQuick
import "../../"
import "../../components"
import "../../services/"

// Dashboard → Stats page.
//
// ── Gating ──────────────────────────────────────────────────────────────────
// `onScreen` must be driven by the OWNING WINDOW's visibility, not by this
// Item's own `visible`. An Item inside a hidden window still reports
// visible === true, so the previous `active: root.visible` bindings kept all six
// telemetry services polling for the rest of the session once the stats page had
// been selected even once — dashboard closed, screen off, session locked, it made
// no difference. That single binding was the largest idle cost in the shell.
//
// It defaults to false, deliberately: an unwired instantiation shows no data,
// which is immediately obvious, rather than silently draining the battery.
Item {
    id: root

    // Set by the owning window: "the stats page is genuinely in front of a user".
    property bool onScreen: false

    ServiceRef {
        service: CpuService
        active: root.onScreen
    }
    ServiceRef {
        service: MemService
        active: root.onScreen
    }
    ServiceRef {
        service: NetService
        active: root.onScreen
    }
    ServiceRef {
        service: DiskService
        active: root.onScreen
    }
    ServiceRef {
        service: GpuService
        active: root.onScreen
    }
    ServiceRef {
        service: CpuFreqService
        active: root.onScreen
    }
    ServiceRef {
        service: PowerProfileService
        active: root.onScreen
    }

    Column {
        anchors {
            fill: parent
            bottomMargin: 8
            topMargin: 8
        }
        spacing: 8

        // Speedometers
        Row {
            id: speedoRow

            width: parent.width
            anchors.topMargin: 4
            height: 160
            spacing: 8

            StatCard {
                width: (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label: "CPU"
                    percent: CpuService.usagePercent
                    centerText: CpuService.usagePercent + "%"
                    bottomText: CpuFreqService.curFreqStr
                    active: true
                    accentColor: Theme.active
                }
            }

            StatCard {
                width: (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label: "RAM"
                    percent: MemService.usagePercent
                    centerText: MemService.usagePercent + "%"
                    bottomText: MemService.usedStr + " / " + MemService.totalStr
                    active: true
                    // KEPT deliberately. These three gauges sit in one row and need
                    // to be told apart at a glance, so RAM and iGPU carry their own
                    // hue while CPU uses the accent. That makes them SERIES colours,
                    // and the shell has no series palette — mapping them onto
                    // Theme.subtext/iconFont would be a similar-looking token, not a
                    // correct one. Needs a designed 3-colour series, not a rename.
                    accentColor: "#cba6f7"
                }
            }

            StatCard {
                width: (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label: "iGPU"
                    percent: GpuService.igpu.usagePercent
                    centerText: GpuService.igpu.usagePercent + "%"
                    bottomText: GpuService.igpu.curMhz
                    active: GpuService.available
                    accentColor: "#89dceb"   // KEPT — series colour, see the RAM gauge above
                }
            }
        }

        // Net | Disk | Power
        Row {
            width: parent.width
            height: parent.height - speedoRow.height - parent.spacing
            spacing: 8

            // Network — narrow, only 3 rows
            StatCard {
                width: Math.round(parent.width * 0.20)
                height: parent.height
                NetStatsPanel {
                    anchors.fill: parent
                    service: NetService
                }
            }

            // Disks — moderate, horizontal bars stack vertically
            StatCard {
                width: Math.round(parent.width * 0.35)
                height: parent.height
                DiskPanel {
                    anchors.fill: parent
                    service: DiskService
                }
            }

            // Power — widest, two button rows need space
            StatCard {
                width: parent.width - Math.round(parent.width * 0.20) - Math.round(parent.width * 0.35) - parent.spacing * 2
                height: parent.height
                PowerPanel {
                    anchors.fill: parent
                    powerProfileService: PowerProfileService
                }
            }
        }
    }
}
