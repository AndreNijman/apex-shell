import QtQuick
import "../"
import "../../"
import "../agentgraph.js" as Graph

// One thing a session started: a Claude subagent, or a process it forked
// (roadmap P1-020).
//
// Drawn under its session's row and indented, because that is the whole point
// — until this existed, an agent with six subagents working and an agent
// sitting idle were the same single row saying "working".
//
// ── WHY IT DOES NOT REUSE StateBadge ────────────────────────────────────────
//
// StateBadge draws one of the seven runtime states, and a child has none of
// them. It has `started` and possibly `ended`, and what it is doing is a
// conclusion drawn from those two and from whether its session is still alive.
// Giving a child a badge would mean inventing a state to put in it, which is
// the exact thing agentgraph.js exists to avoid: a status field is a claim
// that was true when it was written, and a subagent whose stop event never
// arrived would go on claiming it was working forever.
//
// So the mark here is a dot, not a badge, and its colour comes from the
// derived word rather than from a stored state.
//
// ── THE FOUR WORDS ARE FOUR DIFFERENT FACTS ─────────────────────────────────
//
//   running                  open, and its session is alive
//   finished                 the agent published subagent_stop for it
//   ended with the turn      the turn ended while it was still open
//   ended with the session   the session's process is gone
//   unknown                  open under a session that has exited
//
// Only "finished" is a subagent that finished. The middle two are the runtime
// saying it can no longer tell — a subagent CAN outlive the turn that started
// it — and painting those in the success tone would be a small lie repeated on
// every row. They get the muted foreground instead, which is what "no news"
// looks like everywhere else on this page.

Item {
    id: kid

    // A ChildInfo from SessionInfo.children.
    required property var child
    // The session it hangs off. Needed, not optional: liveness is a question
    // about BOTH, and a child cannot answer it alone.
    required property var session

    // Set for a process node that stands for a subtree, so the row can say
    // what it is standing for rather than quietly under-reporting.
    property int subtreeCount: 1
    property real subtreeRssKb: 0

    readonly property bool isProcess: kid.child.kind === "process"
    readonly property var line: Graph.subagentLine(kid.child, kid.session,
                                                  Date.now() / 1000)

    // Running is the only one worth a colour. `finished` is good news that has
    // already happened, and a list that shouts about everything teaches people
    // to stop reading it.
    readonly property color tone:
        kid.line.live ? Theme.info
      : kid.line.certain ? Theme.subtext
      : Theme.subtext

    implicitHeight: Theme.px(20)
    height: implicitHeight

    Rectangle {
        id: dot
        anchors.left: parent.left
        anchors.leftMargin: Theme.px(2)
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.px(5)
        height: width
        radius: width / 2
        color: kid.tone
        opacity: kid.line.live ? 1.0 : 0.45
    }

    Row {
        anchors.left: dot.right
        anchors.leftMargin: Theme.px(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Text {
            id: nameText
            text: kid.isProcess ? kid.child.label : kid.line.label
            color: Theme.text
            opacity: kid.line.live ? 1.0 : 0.7
            font.pixelSize: Theme.fs(10)
            elide: Text.ElideRight
            width: Math.min(implicitWidth,
                            Math.max(0, parent.width - restText.implicitWidth))
        }
        Text {
            id: restText
            // A process read out of /proc is running by definition, so the word
            // would be the same on every one of them and says nothing. What a
            // process row owes the reader is its size and how much of the tree
            // it stands for.
            text: {
                var bits = []
                if (kid.isProcess) {
                    if (kid.subtreeCount > 1)
                        bits.push("+" + (kid.subtreeCount - 1))
                    if (kid.subtreeRssKb > 0)
                        bits.push(Graph.memoryLabel(kid.subtreeRssKb))
                } else {
                    bits.push(kid.line.state)
                    if (kid.line.age !== "") bits.push(kid.line.age)
                }
                return bits.length ? "  ·  " + bits.join("  ·  ") : ""
            }
            color: Theme.subtext
            font.pixelSize: Theme.fs(10)
        }
    }
}
