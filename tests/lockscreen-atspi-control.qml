import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
//  lockscreen-atspi-control.qml — the CONTROL for tests/run-lockscreen-atspi.sh.
//
//  This file is not a test of anything in this repository. It is the thing that
//  makes the suite's negative results mean something.
//
//  run-lockscreen-atspi.sh stands up a private accessibility bus and a private
//  headless compositor and reads back what the shell publishes. It finds
//  nothing below the application node. "Nothing" has two possible causes and
//  they are indistinguishable from the shell's side:
//
//    * the shell really does publish no accessible windows, or
//    * the harness is broken — the a11y status flags never took, the registry
//      never came up, the walker is pointed at the wrong bus, the compositor
//      never mapped anything.
//
//  So the suite runs THIS first, on the same compositor, the same session bus,
//  the same accessibility bus and the same walker, in the same run. It is a
//  plain Qt Quick Window with one labelled Text in it, driven by the stock
//  `qml` runtime. If its three nodes come back over D-Bus, every piece of the
//  harness demonstrably works, and the empty tree measured afterwards is a fact
//  about the program under test.
//
//  A harness with no control is the defect family this unit keeps meeting: a
//  gate that runs and inspects nothing. An empty accessibility tree looks
//  exactly like a surface with no markup, and it also looks exactly like a test
//  that forgot to connect.
//
//  Kept deliberately minimal — one window, one named label. Everything the
//  suite asserts about it is something the LOCK SCREEN would also have to
//  publish to be readable: a frame for the surface, and a node carrying an
//  Accessible.name written in QML and arriving verbatim on the bus.
// ─────────────────────────────────────────────────────────────────────────────

Window {
    visible: true
    width:  320
    height: 200
    title:  "apex-atspi-control"

    Text {
        anchors.centerIn: parent
        text: "control"

        // The two things the suite reads back off the bus. Both are mutated by
        // tests/mutate-lockscreen-atspi.sh, because a control nobody can break
        // is not a control.
        Accessible.role: Accessible.StaticText
        Accessible.name: "apex-atspi-control-label"
    }
}
