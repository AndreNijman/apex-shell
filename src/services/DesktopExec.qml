pragma Singleton
import QtQuick
import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// DesktopExec — launch a DesktopEntry the way its own file asked to be launched.
//
// ── The defect this exists for ──────────────────────────────────────────────
//
// /usr/share/applications/nvim.desktop ships from the neovim rpm on every APEX
// image and declares `Terminal=true`. `apex install neovim` refuses it — and is
// right to: files/system/libexec/apex-pkg skips a package whose exact NEVRA the
// image already provides, so an overlay can never shadow the image's copy. The
// user is told the editor is "provided by APEX-OS", clicks it, and nothing
// happens.
//
// The binary was never the problem. `nvim --version` exits 0 on every machine
// checked, and /usr/bin/nvim is a real 64-bit ELF from
// neovim-0.11.6-1.fc43.x86_64. The launch was the problem: nvim was started
// with its stdio on pipes, drew its UI into one of them and died.
//
// src/services/AppLauncher.qml said, in a comment above the call,
// that `entry.execute()` "respects Terminal=, Path= and Exec field codes".
// That was a claim. tests/run-terminal-entry-test.sh measured it on
// quickshell-0.3.1 under a headless compositor:
//
//     term.runInTerminal = 1        Terminal=true IS parsed
//     term.command       = ["apex-probe-record"]          %F IS stripped
//     raw    → ran=1  stdout_tty=0  fd1=/dev/null   pwd=<Path=>
//     termed → ran=1  stdout_tty=1  fd1=/dev/pts/1  pwd=<Path=>
//
// So two of the three were true — the field codes are stripped and Path= is
// honoured, both measured, not taken from the comment — and the one that
// mattered was not: the program's stdio went to /dev/null. An entry
// that needs a terminal gets none, and every terminal application APEX ships —
// nvim, and anything else a package drops in with Terminal=true — is
// unclickable.
//
// ── Why the routing lives here and not in the launcher ──────────────────────
//
// There are two places a desktop entry is launched from: the launcher popup
// (src/services/AppLauncher.qml) and the dock (src/modules/Left/AppDock.qml).
// Fixing one leaves the same entry broken from the other, which is exactly the
// kind of half-repair that makes a defect look intermittent. Both now call
// here, and there is no third caller of `entry.execute()` in the tree.
//
// ── Why xdg-terminal-exec, and why nothing behind it ────────────────────────
//
// `xdg-terminal-exec` is the freedesktop helper a `Terminal=true` entry is
// supposed to be launched through: it is the one indirection that lets a user
// choose their terminal once, for the whole desktop, instead of every launcher
// hard-coding a list. APEX ships an implementation of it in apex-os
// (files/system/bin/xdg-terminal-exec, asserted present at build time in
// Containerfile.core), which resolves $TERMINAL and then the emulators the
// image actually carries.
//
// There is deliberately NO fallback chain here. A chain in QML would silently
// paper over a shell running on an image too old to carry the helper, and the
// symptom would come back later as "sometimes it opens the wrong terminal". The
// two halves are one change and land together; the image asserts the helper
// exists, so if it is missing the build is what fails, not the click.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    // The freedesktop indirection. Named once, because the suite asserts the
    // shell asks for this and nothing else.
    readonly property string terminalHelper: "xdg-terminal-exec"

    // Launch `entry`. Returns true if the launch was made.
    //
    // A Terminal=false entry goes straight to Quickshell's own execute(). The
    // suite measures that execute() puts the program in the entry's Path= and
    // strips the Exec field codes, so those two thirds of the old comment are
    // now evidence rather than assertion, and are not worth reimplementing.
    function launch(entry) {
        if (!entry)
            return false

        if (!entry.runInTerminal) {
            entry.execute()
            return true
        }

        // entry.command is the Exec line already parsed into argv with the
        // field codes removed — measured, not assumed: an entry reading
        // `Exec=nvim %F` yields ["nvim"]. Passing argv rather than a string
        // keeps a filename with a space in it from becoming two arguments.
        const argv = []
        for (const a of entry.command)
            argv.push(a)
        if (argv.length === 0) {
            // Nothing parseable to hand a terminal. Upstream's own path is a
            // better failure than an empty terminal window.
            entry.execute()
            return false
        }

        const ctx = ({ "command": [root.terminalHelper].concat(argv) })
        // Path= in the entry. Routing away from execute() means Path= stops being
        // handled for free, so it is carried here and asserted in the suite —
        // an untested branch in a launch path is how the Terminal= bug lasted.
        // The helper takes no directory argument (the spec gives it none), so
        // the terminal inherits this as its cwd and the program starts there.
        const wd = entry.workingDirectory
        if (wd && wd !== "")
            ctx.workingDirectory = wd

        Quickshell.execDetached(ctx)
        return true
    }
}
