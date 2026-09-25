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

    Repeater {
        model: root.options
        delegate: ApexPressable {
            id: pill
            required property var modelData
            readonly property var    _val: (modelData && modelData.value !== undefined) ? modelData.value : modelData
            readonly property string _lbl: (modelData && modelData.label !== undefined) ? modelData.label : modelData
            readonly property bool   active: root.value === _val
            readonly property bool   dimmed: !!(modelData && modelData.dimmed)
            readonly property string _hint: (modelData && modelData.hint) ? modelData.hint : ""

            // Each pill is its own control: it has its own words, its own
            // selected state, and a keyboard user has to be able to reach and
            // choose each one. The group's meaning ("Scaling mode") comes from
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
