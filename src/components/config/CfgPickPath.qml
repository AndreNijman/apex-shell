import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// CfgPickPath — "Choose…": a real file or folder picker, where one exists.
//
// A settings row that takes a path keeps a text field as the control that
// always works. This sits beside it and opens zenity's or kdialog's dialog
// when either is installed — the image guarantees neither — and is simply
// absent when neither is. The chosen path arrives through `picked`; nothing
// is written until the row decides to.
//
//   CfgPickPath { directory: true; start: somePath; onPicked: function(p) { … } }
// ─────────────────────────────────────────────────────────────────────────────
CfgButton {
    id: root

    property bool   directory: false
    property string title:     directory ? "Choose a folder" : "Choose an image"
    property string start:     ""
    signal picked(string path)

    label: "Choose…"
    icon:  "󰉋"
    visible: root._tool !== ""

    property string _tool: ""
    property Process _probe: Process {
        running: true
        command: ["sh", "-c", "command -v zenity || command -v kdialog || true"]
        stdout: StdioCollector {
            onStreamFinished: root._tool = String(this.text).trim().split("\n")[0] || ""
        }
    }
    property Process _dialog: Process {
        stdout: StdioCollector {
            onStreamFinished: {
                const p = String(this.text).trim()
                if (p !== "") root.picked(p)
            }
        }
    }

    onClicked: {
        if (root._dialog.running || root._tool === "") return
        const from = root.start !== "" ? root.start : ((Quickshell.env("HOME") || "") + "/")
        const images = "*.png *.jpg *.jpeg *.webp *.gif *.bmp *.svg"
        if (root._tool.endsWith("zenity"))
            root._dialog.command = root.directory
                ? ["zenity", "--file-selection", "--directory", "--title", root.title, "--filename", from]
                : ["zenity", "--file-selection", "--title", root.title, "--filename", from,
                   "--file-filter", "Images | " + images]
        else
            root._dialog.command = root.directory
                ? ["kdialog", "--getexistingdirectory", from, "--title", root.title]
                : ["kdialog", "--getopenfilename", from, "Images (" + images + ")", "--title", root.title]
        root._dialog.running = true
    }
}
