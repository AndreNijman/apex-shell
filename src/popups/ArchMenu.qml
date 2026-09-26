import QtQuick
import Quickshell
import Quickshell.Wayland
import "../shapes/fluid"
import "../shapes/fluid/geometry.js" as Geo
import "../services"
import "../components"
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// ArchMenu — the power menu, out of the left screen strip
// (UI/UX roadmap v3 Phase 10, LEFT_SPILL).
//
// The body is geometry.js leftSpill: a short full-width bar extrudes out of the
// strip first, firmly, on emphasizedDecel, then it unfolds vertically,
// symmetric about the strip's middle, from 25 % — horizontal emergence first,
// which is what distinguishes it from the right side's pour and from the quick
// controls' drip. Its fillets start at the strip's inner edge with a vertical
// tangent (brief A.3: starting them at the screen edge put a kink where they
// crossed the strip). Content is laid out once, at its finished place, and
// revealed by the body's clip; a page change retargets width and height over a
// page beat.
//
// A PanelWindow with the left strip's own extent, on the Overlay layer. It was
// a PopupWindow of the strip, placed by an anchor rectangle, sized to the
// largest page so its input region could not leave the surface (labwc clips
// such a region strictly and the menu then ignored every click; see
// tests/labwc-matrix-test.qml). Its input region is the body's bounds while
// open and nothing while it closes.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
	id: root

	// The left strip of this screen; it is only asked which screen that is.
	required property var anchorWindow
	screen: root.anchorWindow.screen
	readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForScreen(root.screen) }   // P1-040: this output's sizes

	readonly property int fw: theme.radiusL     // the fillet into the strip
	readonly property int fh: theme.radiusL
	readonly property int pad: theme.px(6)
	// Left of the content: clear of the spill's content clip, which starts
	// half a fillet in from the strip.
	readonly property int inL: Math.max(theme.px(14), Math.ceil(theme.radiusL / 2) + theme.px(2))

	readonly property var pageHeights: ({
		"power":       270,
		"performance": 190,
		"stats":       250
	})
	readonly property var pageWidths: ({
		"power":       220,
		"performance": 260,
		"stats":       390
	})

	readonly property int contentWidth:  theme.px(pageWidths[page]  ?? 220)
	// The power page is as tall as its rows (which actions exist varies:
	// Windows and Gaming Mode appear only where they work); the others keep
	// their table heights.
	readonly property int contentHeight: page === "power" && powerMenu.implicitHeight > 0
	                                     ? powerMenu.implicitHeight + 16   // PopupPage's padV, both sides
	                                     : theme.px(pageHeights[page] ?? 220)

	property string page: "power"

	// Wide enough for the widest page, its padding and the fillet.
	readonly property int maxPageWidth: {
		let m = 0
		for (const k in pageWidths) m = Math.max(m, pageWidths[k])
		return theme.px(m)
	}

	anchors.top:    true
	anchors.bottom: true
	anchors.left:   true
	margins.top:    theme.notchHeight
	margins.bottom: theme.cornerRadius
	implicitWidth:  theme.borderWidth + root.inL + root.maxPageWidth + root.pad + root.fw

	exclusionMode: ExclusionMode.Ignore
	color:         "transparent"
	WlrLayershell.layer:         WlrLayer.Overlay
	// The keyboard while it is open (UI/UX Phase 21): it took none, so its
	// power rows — ApexPressable, Tab-ready — could not be reached, and on labwc
	// (where PopupDismiss stands aside for it) nothing closed it but a click.
	WlrLayershell.keyboardFocus: Popups.archMenuOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
	Item {
		focus: Popups.archMenuOpen
		Keys.onEscapePressed: Popups.archMenuOpen = false
	}

	SurfaceLifecycle {
		name: "power"
		id: life
		open:          Popups.archMenuOpen
		enterDuration: Motion.surfaceEnterSmall
		exitDuration:  Motion.surfaceExitSmall
		// Liquid: the width extrudes first, the height unfolds after it and
		// swells a hair past its mark, the fillets trail; it waits for this
		// window's first frame, so it grows out of the strip.
		liquid:  true
		surface: body
	}
	visible: life.mapped

	// The finished body, retargeting over a page beat while it is up.
	property real targetW: root.inL + root.contentWidth + root.pad
	property real targetH: root.contentHeight + root.pad * 2
	Behavior on targetW { enabled: life.progress > 0; MotionSpring { role: "page" } }
	Behavior on targetH { enabled: life.progress > 0; MotionSpring { role: "page" } }

	readonly property var spillGeometry: ({
		x0: theme.borderWidth,
		cy: Math.round(root.height / 2),
		w:  root.targetW,
		h:  root.targetH,
		r:  theme.radiusL,
		rm: theme.radiusM
	})
	// What the body covers once it has finished opening — for the input
	// region's own test, which must not depend on catching the open mid-way.
	readonly property var openBounds: Geo.leftSpill(1, root.spillGeometry).bounds

	// ── Body ──────────────────────────────────────────────────────────────────
	Item {
		id: bodyFade
		anchors.fill: parent
		// The ridge a spill starts from (16 px wide, geometry.js) is already a
		// shape: it fades in over the next 24 px of width, so it neither appears
		// nor vanishes on one frame — keyed to WIDTH, because the extrusion is
		// so steep that by 8 % progress the body is already ~140 px wide, and a
		// fade over progress left a translucent box at the end of every close.
		// Both ways since the springs wait for the first frame: that frame IS
		// the ridge (it used to be far wider than the ramp). And on a wrapper, not on the shape: read
		// from the shape's own opacity, its `result` was a binding loop (logged)
		// that left the opacity a frame stale — a translucent first frame. It
		// reads `closing`, not `open`, for the same reason (SurfaceLifecycle).
		opacity:  life.alpha * Math.min(1, Math.max(0,
		              (Geo.leftSpillWidth(life.progress, body.chGeometry) - Geo.spillRidge(body.geometry)) / 24))

		FluidShape {
			id: body
			anchors.fill: parent
			family:   "leftSpill"
			progress: life.progress
			channels: ({ w: life.lead, d: life.body, n: life.trail, fw: life.leadFlow, fd: life.bodyFlow })
			readonly property var chGeometry: Object.assign({}, geometry, { ch: channels })
			color:    Theme.background
			geometry: root.spillGeometry
		}
	}

	mask: Region { item: hit }
	Item {
		id: hit
		x: life.open ? body.result.bounds.x : 0
		y: life.open ? body.result.bounds.y : 0
		width:  life.open ? body.result.bounds.w : 0
		height: life.open ? body.result.bounds.h : 0
	}

	// ── Content, at its finished layout, revealed by the body's clip ─────────
	Item {
		id: reveal
		x: body.result.clip.x; y: body.result.clip.y
		width: body.result.clip.w; height: body.result.clip.h
		clip: true
		// Keys travel up from the focused row, so Escape lives on an ancestor
		// of the rows too — the catcher above only has it before any Tab.
		Keys.onEscapePressed: Popups.archMenuOpen = false

		Item {
			// Window coordinates: the finished body, inset.
			x: theme.borderWidth + root.inL - reveal.x
			y: Math.round(root.height / 2 - root.contentHeight / 2) - reveal.y
			width:  root.contentWidth
			height: root.contentHeight

			opacity: life.content
			transform: Translate { x: (1 - life.content) * -Motion.travel(theme.px(8)) }

			PopupPage {
				anchors.fill: parent
				visible: root.page === "power"

				PowerMenu {
					id: powerMenu
					width: parent.width
				}
			}
		}
	}
}
