import QtQuick
import "../../"
import "../controls"

// Wrapping set of selectable pills. `options` accepts either an array of strings
// or an array of { value, label }. Bind `value`; handle `selected(value)`.
// An option may also carry `dimmed: true` and a `hint`: it is drawn greyed out
// but stays selectable — for a choice that works but is not a good fit, where
// the caller explains why once it is picked.
//
// Each pill is an ApexPressable (UI/UX roadmap v3 Phase 16): it dips when
// pressed, hovers as a state layer, rings only for keyboard focus, and draws
// with the palette's roles. The chosen one is surfaceSelected with its label
// in the accent at once. Unlike the tabs, the selection does not travel
// between pills: this is a Flow that wraps, and a pill sliding across rows
// reads worse than a cross-fade on the state beat.
Flow {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    property var options: []
    property var value:   ""
    signal selected(var value)
    spacing: 6

    // ── Keyboard (UI/UX roadmap v3 Phase 21) ─────────────────────────────────
    // A radio group: ONE Tab stop, landing on the chosen pill; the arrows move
    // between pills (Left/Right in reading order, Up/Down too), Home/End to the
    // ends, and Space/Return choose. Every pill was its own Tab stop — a page
    // of these was a long walk. The arrows move focus and do NOT choose: many
    // pages apply at once (Light or dark and the colour scheme re-run matugen),
    // and arrowing across them must not apply each one on the way.
    property int _focusIdx: -1        // the pill the arrows are on, while inside
    function _valOf(o) { return (o && o.value !== undefined) ? o.value : o }
    readonly property int _activeIdx: {
        for (var i = 0; i < root.options.length; i++)
            if (root._valOf(root.options[i]) === root.value) return i
        return -1
    }
    readonly property int _stop: root._focusIdx >= 0 ? root._focusIdx : Math.max(0, root._activeIdx)
    function _focus(i) {
        const it = pills.itemAt(Math.max(0, Math.min(root.options.length - 1, i)))
        if (it) it.forceActiveFocus()
    }
    function _leftGroup() {
        for (var i = 0; i < pills.count; i++)
            if (pills.itemAt(i) && pills.itemAt(i).activeFocus) return
        root._focusIdx = -1           // re-entering lands on the chosen pill again
    }

    Repeater {
        id: pills
        model: root.options
        delegate: ApexPressable {
            id: pill
            required property var modelData
            required property int index
            activeFocusOnTab: pill.interactive && pill.index === root._stop
            onActiveFocusChanged: {
                if (pill.activeFocus) root._focusIdx = pill.index
                else Qt.callLater(root._leftGroup)
            }
            // Left/Right follow the reading direction: in a mirrored row the
            // pill to the left is the next one. Read from the application's
            // direction, which is what CfgScroll mirrors every page from.
            readonly property int _ahead: Qt.application.layoutDirection === Qt.RightToLeft ? -1 : 1
            Keys.onLeftPressed:  function (e) { root._focus(pill.index - pill._ahead); e.accepted = true }
            Keys.onRightPressed: function (e) { root._focus(pill.index + pill._ahead); e.accepted = true }
            Keys.onUpPressed:    function (e) { root._focus(pill.index - 1); e.accepted = true }
            Keys.onDownPressed:  function (e) { root._focus(pill.index + 1); e.accepted = true }
            Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Home)     { root._focus(0); e.accepted = true }
                else if (e.key === Qt.Key_End) { root._focus(root.options.length - 1); e.accepted = true }
            }
            readonly property var    _val: (modelData && modelData.value !== undefined) ? modelData.value : modelData
            readonly property string _lbl: (modelData && modelData.label !== undefined) ? modelData.label : modelData
            readonly property bool   active: root.value === _val
            readonly property bool   dimmed: !!(modelData && modelData.dimmed)
            readonly property string _hint: (modelData && modelData.hint) ? modelData.hint : ""

            // Each pill is its own control: it has its own words, its own
            // selected state, and a keyboard user has to be able to reach and
            // choose each one (through the arrows, above). The group's meaning ("Scaling mode") comes from
            // the CfgRow around it; what a pill must say for itself is which
            // option it is and whether it is the chosen one.
            objectName: "cfgSegmentedPill"
            Accessible.role:      Accessible.RadioButton
            Accessible.checkable: true
            Accessible.checked:   pill.active
            Accessible.name:      String(pill._lbl)
            Accessible.description: pill._hint
            function choose() { root.selected(pill._val) }
            onActivated: pill.choose()

            height: 26
            width:  t.implicitWidth + 20
            radius: theme.radiusS
            Rectangle {
                anchors.fill: parent
                radius: pill.radius
                opacity: pill.dimmed ? (pill.active ? 0.7 : 0.4) : 1.0
                color: pill.tint(pill.active ? Theme.surfaceSelected : Theme.surfaceRaised)
                border.width: 1
                border.color: pill.active
                    ? Qt.rgba(Theme.accentText.r, Theme.accentText.g, Theme.accentText.b, 0.42)
                    : Theme.outlineSoft
                Behavior on color        { MotionColor { role: "state" } }
                Behavior on border.color { MotionColor { role: "state" } }
            }

            Text {
                id: t
                anchors.centerIn: parent
                text:           pill._lbl
                font.pixelSize: theme.fs(11)
                font.weight:    pill.active ? Font.Medium : Font.Normal
                // At once, so the choice reads before anything else moves.
                color:          pill.active ? Theme.accentText : Theme.textSecondary
                opacity:        pill.dimmed ? (pill.active ? 0.7 : 0.55) : 1.0
            }
            ApexFocusRing { target: pill }
        }
    }
}
