pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// DiskService — per-device usage, from df.
//
// Singleton + refcounted. This one keeps its subprocess: free space per mount
// comes from statvfs(), which /proc does not expose and QML cannot call.
// /proc/self/mountinfo lists mounts but carries no usage figures, so `df`
// remains the only route. What changed is that it no longer runs unconditionally
// for the whole session from two hardcoded `active: true` call sites — it runs
// every 15s only while something is actually displaying disks.
//
// Exposes:
//   var disks — [{ source, mount, usedPct, usedStr, totalStr }]
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 15000

    property var disks: []

    // Pseudo-filesystems are excluded by TYPE rather than by requiring a
    // "/dev/..." source. The old `grep '^/dev/'` dropped every root that is not
    // a plain block device — composefs/ostree (APEX-OS's own base), ZFS
    // ("rpool/ROOT"), btrfs subvolumes and network mounts all vanished, leaving
    // the disk card blank or showing only /boot.
    readonly property Process proc: Process {
        command: ["sh", "-c", "df -BM --output=source,fstype,size,used,pcent,target" + " -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay -x ramfs" + " -x autofs -x fuse.portal -x fuse.gvfsd-fuse -x nsfs -x binfmt_misc" + " 2>/dev/null | tail -n +2"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._parse(text)
        }
    }

    function _parse(text) {
        const lines = (text || "").trim().split("\n")
        const result = []
        const seen = ({})          // source → index in result (dedupe)

        for (let i = 0; i < lines.length; i++) {
            if (lines[i].trim() === "")
                continue
            const parts = lines[i].trim().split(/\s+/)
            // source  fstype  size  used  pcent  target
            if (parts.length < 6)
                continue

            const source = parts[0]
            const total = parts[2]   // e.g. "230004M"
            const used = parts[3]
            const pct = parts[4]     // e.g. "78%"
            // Mountpoints may contain spaces (e.g. /run/media/u/My Disk), and
            // target is the last column, so re-join everything after pcent.
            const mount = parts.slice(5).join(" ")

            // One physical device can be mounted many times (btrfs subvolumes,
            // ostree bind-mounts). Keep a single row per device, preferring the
            // shallowest mountpoint so "/" wins over "/var/home".
            if (seen.hasOwnProperty(source)) {
                const prev = result[seen[source]]
                if (mount.length >= prev.mount.length)
                    continue
                prev.mount = mount
                continue
            }

            seen[source] = result.length
            result.push({
                "source": source.replace("/dev/", ""),
                "mount": mount,
                "usedPct": parseInt(pct) || 0,
                "usedStr": root._fmt(used),
                "totalStr": root._fmt(total)
            })
        }

        root.disks = result
    }

    // "180000M" → "175 GB", or keep as MB below 1 GiB.
    function _fmt(mibStr) {
        const n = parseInt(mibStr)
        if (isNaN(n))
            return mibStr
        if (n >= 1024)
            return (n / 1024).toFixed(0) + " GB"
        return n + " MB"
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.proc.running = false
            root.proc.running = true
        }
    }
}
