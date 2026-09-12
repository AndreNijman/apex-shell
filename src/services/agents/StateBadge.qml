import QtQuick
import "../"
import "../../"
import "../agentstate.js" as AgentState

// The one place an agent's state becomes something you can see.
//
// Local sessions and remote ones both draw this, so a working agent on the
// desktop and a working agent on this laptop look identical — they are the same
// fact about the world, and the two rows had already drifted into two copies of
// the same ternary before this component existed.
//
// ── WHAT IT DRAWS, AND WHY THAT AND NOT JUST A COLOUR ───────────────────────
//
// A chip, a glyph, and — for the two states you must not miss — a fill. The
// mapping from state to tone, token and weight is agentstate.js's; the long
// argument for it lives there. What is here is only the drawing:
//
//   solid     the tone as a fill, glyph in whichever of the fixed-contrast
//             foregrounds actually reads on it. Reserved for `blocked` and
//             `failed`, the two states that mean somebody has to do something.
//   tint      the tone at 0.18, glyph in the tone. `working`.
//   outline   a ring in the tone, nothing filled. `waiting` — present, not
//             shouting.
//   plain     no chip. `done` and `idle`; a finished session is not a status.
//
// The weight is the point. Hue alone cannot separate `failed` from `done` for a
// red-green colourblind reader, and those are the two that matter most; shape
// and ink do it without depending on the eye. Which weight goes where was
// decided by simulation rather than by taste — see agentstate.js.
//
// `toneColor` is exposed because the row draws a stripe in it. That stripe is
// the reason the page reads as coloured at a glance rather than as a list of
// white text with one small badge on each line.

Item {
    id: badge
    readonly property ThemeSet theme: Theme.setForHeight(Screen.height)   // P1-040: this output's sizes


    // A runtime state string: starting, working, waiting_for_user,
    // permission_request, complete, failed, exited. Anything else is drawn as
    // idle rather than guessed at.
    property string sessionState: ""

    // Callers size this; the glyph follows.
    property real size: theme.px(24)

    readonly property string tone:   AgentState.tone(badge.sessionState)
    readonly property string weight: AgentState.weight(badge.sessionState)

    // The token is a NAME on Theme, looked up rather than switched on, so
    // agentstate.js stays the only file that decides which token a state gets.
    // A property read through [] is captured by the binding exactly as a dotted
    // one is, so this still re-evaluates when the wallpaper changes the palette.
    readonly property color toneColor: Theme[AgentState.token(badge.sessionState)]

    implicitWidth:  badge.size
    implicitHeight: badge.size
    width:  badge.size
    height: badge.size

    Rectangle {
        id: chip
        anchors.centerIn: parent
        width:  badge.size
        height: badge.size
        radius: badge.size * 0.3

        color: badge.weight === "solid" ? badge.toneColor
             : badge.weight === "tint"
               ? Qt.rgba(badge.toneColor.r, badge.toneColor.g,
                         badge.toneColor.b, 0.18)
               : "transparent"

        border.width: badge.weight === "outline" ? Math.max(1, theme.px(1)) : 0
        border.color: badge.toneColor

        Behavior on color { ColorAnimation { duration: 120 } }
    }

    Text {
        id: glyph
        anchors.centerIn: parent
        text: AgentService.stateIcon(badge.sessionState)
        font.pixelSize: badge.size * 0.62
        color: badge.weight === "solid" ? Theme.onStatus(badge.toneColor)
                                        : badge.toneColor

        // A working session animates; nothing else does. Motion in a status
        // list should mean "this is changing", or it is just noise.
        //
        // On the GLYPH and not on the badge, so the chip behind it holds still
        // — a pulsing fill next to four static ones reads as a rendering fault
        // rather than as progress.
        SequentialAnimation on opacity {
            running: badge.sessionState === "working"
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutQuad }
        }
        onOpacityChanged: if (badge.sessionState !== "working") opacity = 1.0
    }
}
