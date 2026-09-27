import QtQuick
import "../"

// Reusable card background. Wrap any stats panel in this for
// a consistent surface across the stats tab and future dashboard panels.
//
// Usage:
//   StatCard {
//       width: ...; height: ...
//       SomeContent { anchors.fill: parent }
//   }

Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    default property alias content: inner.data
    property int padding: 12

    // A card is a surface, not a bordered box (UI/UX Phase 17, visual roadmap
    // §13/§22): the raised surface level, no border — what sits inside it
    // takes the next level down rather than another outline.
    Rectangle {
        anchors.fill: parent
        radius:       theme.radiusL
        color:        Theme.surfaceRaised
    }

    Item {
        id: inner
        anchors {
            fill:         parent
            margins:      root.padding
        }
    }
}
