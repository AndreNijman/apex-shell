import QtQuick
import "../../"

// One block of AgentHelpContent, drawn according to its `k` (roadmap §43).
//
// A Loader per block rather than one Item carrying every renderer with
// `visible:` on each. A Column reserves space for an invisible child, so the
// visibility version needs `height: visible ? implicitHeight : 0` on items
// whose implicitHeight comes from their own geometry, and that is the binding
// loop AgentCenter.qml:229-235 already documents. The Loader has no such cycle:
// its height reads the loaded item's implicitHeight, and the item's
// implicitHeight reads its children's, which read their width.

Item {
    id: blk

    required property var block

    implicitHeight: holder.height
    height: implicitHeight

    readonly property string _kind: blk.block && blk.block.k ? blk.block.k : "p"
    readonly property string _text: blk.block && blk.block.t ? blk.block.t : ""
    readonly property string _desc: blk.block && blk.block.d ? blk.block.d : ""
    readonly property bool _monoTerm: !!(blk.block && blk.block.mt)
    readonly property bool _monoDesc: !!(blk.block && blk.block.md)

    Loader {
        id: holder
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: item ? item.implicitHeight : 0

        sourceComponent: blk._kind === "h"    ? headingPart
                       : blk._kind === "cmd"  ? commandPart
                       : blk._kind === "kv"   ? termPart
                       : blk._kind === "note" ? notePart
                       : blk._kind === "todo" ? todoPart
                       : paragraphPart
    }

    // ── A sub-heading ─────────────────────────────────────────────────────────
    // The top padding is larger than the bottom so a heading belongs to the
    // paragraph under it rather than floating between two.
    Component {
        id: headingPart
        Item {
            implicitHeight: headingLabel.implicitHeight + Theme.px(22)
            Text {
                id: headingLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                text: blk._text
                color: Theme.text
                font.pixelSize: Theme.fs(12)
                font.bold: true
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── A paragraph ───────────────────────────────────────────────────────────
    Component {
        id: paragraphPart
        Item {
            implicitHeight: bodyLabel.implicitHeight + Theme.px(7)
            Text {
                id: bodyLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: blk._text
                color: Theme.subtext
                font.pixelSize: Theme.fs(11)
                lineHeight: 1.35
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── A command, printed as typed ───────────────────────────────────────────
    Component {
        id: commandPart
        Rectangle {
            implicitHeight: commandLabel.implicitHeight + Theme.px(20)
            radius: Theme.px(6)
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.06)

            Text {
                id: commandLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.px(10)
                text: blk._text
                color: Theme.text
                font.family: "JetBrains Mono"
                font.pixelSize: Theme.fs(10)
                lineHeight: 1.4
                // Wrapped rather than clipped. A command that runs past the
                // pane is unreadable either way, and a wrapped one can at
                // least be read and retyped.
                wrapMode: Text.Wrap
            }
        }
    }

    // ── A term and what it means ──────────────────────────────────────────────
    Component {
        id: termPart
        Item {
            implicitHeight: termColumn.implicitHeight + Theme.px(11)

            Column {
                id: termColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Theme.px(3)

                Text {
                    width: parent.width
                    text: blk._text
                    color: Theme.text
                    font.family: blk._monoTerm ? "JetBrains Mono" : Qt.application.font.family
                    font.pixelSize: Theme.fs(11)
                    font.bold: !blk._monoTerm
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    visible: blk._desc !== ""
                    text: blk._desc
                    color: Theme.subtext
                    font.family: blk._monoDesc ? "JetBrains Mono" : Qt.application.font.family
                    font.pixelSize: Theme.fs(blk._monoDesc ? 10 : 11)
                    lineHeight: 1.35
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    // ── A rule that holds, marked with the accent ─────────────────────────────
    Component {
        id: notePart
        Item {
            implicitHeight: noteLabel.implicitHeight + Theme.px(18)

            Rectangle {
                id: noteBar
                anchors.left: parent.left
                anchors.top: parent.top
                width: Theme.px(2)
                height: noteLabel.implicitHeight
                radius: Theme.px(1)
                color: Theme.active
            }
            Text {
                id: noteLabel
                anchors.left: noteBar.right
                anchors.leftMargin: Theme.px(10)
                anchors.right: parent.right
                anchors.top: parent.top
                text: blk._text
                color: Theme.text
                font.pixelSize: Theme.fs(11)
                lineHeight: 1.35
                wrapMode: Text.WordWrap
            }
        }
    }

    // ── Something the roadmap asks for that this build does not do ────────────
    // Warning-coloured rather than accent-coloured, and labelled, because the
    // failure this guards against is a user reading a plan as a feature.
    Component {
        id: todoPart
        Item {
            implicitHeight: todoColumn.implicitHeight + Theme.px(18)

            Rectangle {
                id: todoBar
                anchors.left: parent.left
                anchors.top: parent.top
                width: Theme.px(2)
                height: todoColumn.implicitHeight
                radius: Theme.px(1)
                color: Theme.warning
            }
            Column {
                id: todoColumn
                anchors.left: todoBar.right
                anchors.leftMargin: Theme.px(10)
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Theme.px(3)

                Text {
                    text: "NOT IN THIS BUILD"
                    color: Theme.warning
                    font.pixelSize: Theme.fs(8)
                    font.bold: true
                    font.letterSpacing: Theme.fs(1)
                }
                Text {
                    width: parent.width
                    text: blk._text
                    color: Theme.subtext
                    font.pixelSize: Theme.fs(11)
                    lineHeight: 1.35
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
