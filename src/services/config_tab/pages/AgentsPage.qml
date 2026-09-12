import QtQuick
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services — the module whose qmldir hands out AgentPolicyService and
// AgentService, reached the way MiscPage reaches SystemStats.
import "../../"
import "../../agentpolicy.js" as Policy
import "../../agentstate.js" as AgentState

// Config → Agents (ROADMAP.md §42.1, P0-016)
//   • Sandbox default — the Always Unrestricted toggle and what it costs
//   • What it does not change — the three things that stay put
//   • Sessions running now — each one's own mode, not this page's setting
//
// ── ONE SETTING, AND A PAGE ANYWAY ──────────────────────────────────────────
//
// The page carries one control. Everything else on it is there because a
// toggle that removes a security boundary and says nothing is a trap: the
// reader has to be able to find out what it removes, what it leaves alone, and
// what is running right now, in the place where they are about to change it.
// §42.1 asks for the page in those words — a clear Agent Settings page — and
// the sentence about what is NOT granted is a requirement, not decoration.
//
// ── WHY THE SESSION LIST IS HERE ────────────────────────────────────────────
//
// A default is a promise about the future. The sessions already running were
// forked with a policy the daemon recorded at the time, and nothing in this
// page moves them. Listing them next to the switch, in their own recorded
// modes, is what stops the page from implying otherwise the moment somebody
// flips it — see the note on the section itself.
//
// ── WHAT THE COPY MAY CLAIM ─────────────────────────────────────────────────
//
// Only what apex-agent-core's tests actually assert.
// `unrestricted_user_does_not_imply_root` runs over every sandbox and every
// native mode and asserts `system == None` and `no_new_privs()` for all of
// them; `raw_secret_export_has_no_route_at_all_in_this_build` asserts
// `validate()` refuses `secrets: export`. So this page says no root, sudo
// fails inside a session, and secrets stay behind the broker. It does not say
// safe, and it does not say contained — an unrestricted session reads and
// writes every file the user can.

CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes


    // Criterion 1. Live: the toggle writes agent.json when you flip it. The
    // failure is NOT hoisted to this line — it stays beside the toggle, which
    // is the only control on the page that writes anything, and a refused
    // password belongs next to the switch that asked for it.
    lifecycle: "live"

    // Set by ShellConfig and Nexus. AgentService is refcounted and forks
    // `apex agent list` on a timer, so the session section below has to be told
    // whether anyone is looking.
    property bool onScreen: false

    ServiceRef { service: AgentService; active: root.onScreen }

    readonly property bool _on: AgentPolicyService.alwaysUnrestricted
    readonly property string _refusal: AgentPolicyService.enableRefusal

    readonly property var _live: AgentService.sessions.filter(function(s) {
        return Policy.isLive(s)
    })
    readonly property var _elsewhere:
        Policy.sessionsOnOtherModes(AgentService.sessions,
                                    AgentPolicyService.defaultSandbox)

    function _modeColor(mode) {
        return Theme[Policy.modeToken(mode)]
    }

    // ── Sandbox default ───────────────────────────────────────────────────────
    CfgSection {
        title: "Sandbox default"
        first: true

        // The indicator §42.1 asks for, at the top of the page that owns the
        // setting. The same component the Agent Center draws, bound to the same
        // property the toggle is, so the two surfaces cannot word it
        // differently or disagree about whether it is on.
        UnrestrictedBanner {
            width:   parent.width
            visible: root._on
            compact: true
        }
        Item { width: parent.width; height: theme.px(6); visible: root._on }

        CfgRow {
            label: "Always unrestricted agents"
            // The off branch names the mode actually in force, not "project".
            // A user whose file says `strict` was being told `project` by this
            // line while the row below it said `strict`.
            description: root._on
                ? "New sessions read and write any file you can."
                : "New sessions get the " + AgentPolicyService.defaultSandbox
                  + " sandbox: your project writable, the rest of $HOME not there."

            CfgSwitch {
                checked: root._on
                opacity: (AgentPolicyService.busy
                          || (!root._on && root._refusal !== "")) ? 0.4 : 1
                Behavior on opacity { NumberAnimation { duration: 120 } }
                onToggled: function(v) {
                    if (AgentPolicyService.busy) return
                    if (v && root._refusal !== "") return
                    AgentPolicyService.setAlwaysUnrestricted(v)
                }
            }
        }

        // What the switch is asking for, before it is pressed. Switching on
        // wants a password at the desktop's own prompt; switching off wants
        // nothing, which §42.1 asks for in as many words.
        Text {
            width: parent.width - theme.px(20)
            x:     theme.px(10)
            text: root._on
                ? "Switching this off takes effect at once and asks for nothing."
                : "Switching this on asks for your password at the desktop's "
                  + "authentication prompt, not in an agent's terminal."
            font.pixelSize: theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6) }

        // Why the toggle will not move, when it will not.
        Text {
            id: refusalText
            width:   parent.width - theme.px(20)
            x:       theme.px(10)
            visible: !root._on && root._refusal !== ""
            text:    "Cannot switch on: " + root._refusal
                   + ". Fix " + AgentPolicyService.configPath + " first."
            font.pixelSize: theme.fs(10)
            color:    Theme.warning
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6); visible: refusalText.visible }

        // What went wrong with the last attempt, including a refused or
        // dismissed password.
        Text {
            id: errorText
            width:   parent.width - theme.px(20)
            x:       theme.px(10)
            visible: AgentPolicyService.lastError !== ""
            text:    AgentPolicyService.lastError
            font.pixelSize: theme.fs(10)
            color:    Theme.danger
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6); visible: errorText.visible }

        CfgRow {
            label: "Stored in"
            description: AgentPolicyService.configPath
                       + ". The agent runtime reads it when it starts a session, so the "
                       + "setting survives a reboot."
            hoverable: false

            Text {
                text: AgentPolicyService.busy ? "saving…"
                                              : AgentPolicyService.defaultSandbox
                font.pixelSize: theme.fs(11)
                font.bold: true
                color: AgentPolicyService.busy
                     ? Theme.subtext
                     : root._modeColor(AgentPolicyService.defaultSandbox)
            }
        }
    }

    // ── What it does not change ───────────────────────────────────────────────
    CfgSection {
        title: "What it does not change"

        Repeater {
            model: [
                { t: "Root",
                  d: "A session keeps the kernel's no_new_privs flag whichever sandbox "
                   + "it has, so sudo and other setuid programs fail inside it. "
                   + "System changes still go through apex request, which a person approves." },
                { t: "Secrets",
                  d: "The broker performs a granted operation and returns its result; "
                   + "the session does not receive the credential. This build has no route "
                   + "that hands over a raw one." },
                { t: "The agent's own permission mode",
                  d: "A separate setting, in both directions. Claude's bypassPermissions "
                   + "stays set if you had it set." }
            ]

            delegate: Item {
                id: claimLine
                required property var modelData
                width:  parent.width
                height: line.implicitHeight + theme.px(14)

                Column {
                    id: line
                    anchors.left:           parent.left
                    anchors.right:          parent.right
                    anchors.leftMargin:     theme.px(10)
                    anchors.rightMargin:    theme.px(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    Text {
                        text:           claimLine.modelData.t
                        font.pixelSize: theme.fs(11)
                        font.bold:      true
                        color:          Theme.text
                    }
                    Text {
                        width:          parent.width
                        text:           claimLine.modelData.d
                        font.pixelSize: theme.fs(10)
                        color:          Theme.subtext
                        wrapMode:       Text.WordWrap
                    }
                }
            }
        }

        // The residual, next to the switch that creates it. The guide used to
        // say a warm sudo timestamp was reachable from an unconfined agent;
        // that was written before apexd/apex-agentd/src/pty.rs set
        // PR_SET_NO_NEW_PRIVS on unconfined sessions too, and sudo now fails
        // inside one whatever the sandbox. What survives is the one thing the
        // flag cannot cover: a process the USER starts later does not inherit
        // it, so a file the session wrote and your shell runs is the way out.
        // Stating that is the difference between a page that describes the
        // boundary and one that oversells it.
        Item { width: parent.width; height: theme.px(6) }
        Text {
            width: parent.width - theme.px(20)
            x:     theme.px(10)
            text: "The caveat is not sudo inside the session, which fails. It is what "
                + "an unconfined session can leave behind: your shell startup files, "
                + "a git hook, a systemd user unit. Those run as you the next time "
                + "you start a shell, with none of a session's limits on them."
            font.pixelSize: theme.fs(10)
            color:    Theme.warning
            wrapMode: Text.WordWrap
        }
    }

    // ── Sessions running now ──────────────────────────────────────────────────
    // §42.1: changing the default must not relabel work already in flight. A
    // session's policy is fixed when the daemon forks it and recorded on the
    // session, so every mode below is read from the session's own record and
    // none of it is read from the setting above. The two genuinely disagree
    // for as long as a session outlives a change, and that is the state this
    // section exists to show.
    CfgSection {
        title: "Sessions running now"

        Text {
            width: parent.width - theme.px(20)
            x:     theme.px(10)
            text: root._live.length === 0
                ? (AgentService.daemonUp
                   ? "Nothing is running. The setting above applies to the next session you start."
                   : "The agent runtime is not running. Start it with  apex agent enable")
                : "Each session keeps the mode it started with. Changing the setting above "
                + "does not move any of them."
            font.pixelSize: theme.fs(10)
            color:    Theme.subtext
            wrapMode: Text.WordWrap
        }
        Item { width: parent.width; height: theme.px(6) }

        Repeater {
            model: root._live

            delegate: Item {
                id: sessionLine
                required property var modelData
                width:  parent.width
                height: theme.px(30)

                readonly property string mode: Policy.sessionSandbox(modelData)
                readonly property string nativeMode: Policy.sessionNative(modelData)

                Row {
                    anchors.left:           parent.left
                    anchors.leftMargin:     theme.px(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(8)

                    Text {
                        text:           AgentState.agentName(sessionLine.modelData.agent)
                        font.pixelSize: theme.fs(11)
                        color:          Theme.text
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text:           "#" + sessionLine.modelData.id
                        font.pixelSize: theme.fs(10)
                        color:          Theme.subtext
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    anchors.right:          parent.right
                    anchors.rightMargin:    theme.px(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(8)

                    Text {
                        visible:        sessionLine.nativeMode !== "inherit"
                        text:           "native " + sessionLine.nativeMode
                        font.pixelSize: theme.fs(10)
                        color:          Theme.subtext
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text:           sessionLine.mode
                        font.pixelSize: theme.fs(11)
                        font.bold:      true
                        color:          root._modeColor(sessionLine.mode)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        Item { width: parent.width; height: theme.px(6) }
        Text {
            width:   parent.width - theme.px(20)
            x:       theme.px(10)
            visible: root._elsewhere.length > 0
            text: root._elsewhere.length === 1
                ? "1 running session is on a different mode from the setting above."
                : root._elsewhere.length
                  + " running sessions are on a different mode from the setting above."
            font.pixelSize: theme.fs(10)
            color:    Theme.warning
            wrapMode: Text.WordWrap
        }
    }
}
