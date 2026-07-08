import QtQuick
import "../../"
import "../../components"
import "../../services/"

Item {
    id: root

    CpuService         { id: cpu;     active: root.visible }
    MemService         { id: mem;     active: root.visible }
    NetService         { id: net;     active: root.visible }
    DiskService        { id: disk;    active: root.visible }
    CpuFreqService      { id: cpuFreq }
    PowerProfileService { id: powerProfile }
    GpuService {
        id:     gpu
        active: root.visible
    }

    Column {
        anchors {
            fill:          parent
            bottomMargin:  8
            topMargin:     8
        }
        spacing: 8

        // Speedometers
        Row {
            id:      speedoRow
            width:   parent.width
            anchors.topMargin: 4
            height:  160
            spacing: 8

            StatCard {
                width:  (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "CPU"
                    percent:     cpu.usagePercent
                    centerText:  cpu.usagePercent + "%"
                    bottomText:  cpuFreq.curFreqStr
                    active:      true
                    accentColor: Theme.active
                }
            }

            StatCard {
                width:  (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "RAM"
                    percent:     mem.usagePercent
                    centerText:  mem.usagePercent + "%"
                    bottomText:  mem.usedStr + " / " + mem.totalStr
                    active:      true
                    accentColor: "#cba6f7"
                }
            }

            StatCard {
                width:  (parent.width - parent.spacing * 2) / 3
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "iGPU"
                    percent:     gpu.igpu.usagePercent
                    centerText:  gpu.igpu.usagePercent + "%"
                    bottomText:  gpu.igpu.curMhz
                    active:      gpu.available
                    accentColor: "#89dceb"
                }
            }
        }
        // Net | Disk | Power
        Row {
            width:   parent.width
            height:  parent.height - speedoRow.height - parent.spacing 
            spacing: 8

            // Network — narrow, only 3 rows
            StatCard {
                width:  Math.round(parent.width * 0.20)
                height: parent.height
                NetStatsPanel {
                    anchors.fill: parent
                    service:      net
                }
            }

            // Disks — moderate, horizontal bars stack vertically
            StatCard {
                width:  Math.round(parent.width * 0.35)
                height: parent.height
                DiskPanel {
                    anchors.fill: parent
                    service:      disk
                }
            }

            // Power — widest, two button rows need space
            StatCard {
                width:  parent.width - Math.round(parent.width * 0.20) - Math.round(parent.width * 0.35) - parent.spacing * 2
                height: parent.height
                PowerPanel {
                    anchors.fill:        parent
                    powerProfileService: powerProfile
                }
            }
        }
    }
}
