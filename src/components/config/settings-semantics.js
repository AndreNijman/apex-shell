// ─── settings-semantics.js ───────────────────────────────────────────────────
// The words the settings pages are allowed to use, and what each one promises.
//
// Kept out of the QML for the reason src/services/agentstate.js is: this is the
// part every page has to agree on, and tests/settings-semantics-test.js
// exercises THIS file — the one the shell loads — rather than a copy of it.
// Nothing here does I/O; the functions are string → string, so a node process
// can drive all of them and also read the pages back against them.
//
// ── WHY THIS FILE EXISTS (roadmap P0-023) ───────────────────────────────────
//
// Ten settings surfaces had grown three unrelated mental models and no shared
// words for any of them. A survey of the tree before this landed:
//
//   Display     stages, applies for a countdown, then asks to keep or revert
//   Blueprint   stages, saves to a file, applies to the machine — three acts
//   Keybinds    stages, and one button labelled Save wrote the file AND
//               reloaded the compositor
//   the other six  write as you touch them, and their only way out is a button
//               labelled Reset that meant something different on each page
//
// Every page was defensible on its own. Together they meant a user could not
// carry an expectation from one page to the next: Save persisted something
// already real on one page, made something real on another, and did not exist
// on six.
//
// ── WHAT THIS FILE IS NOT ───────────────────────────────────────────────────
//
// It is not a plan to make every page staged. A brightness slider that needs a
// Save click is a regression wearing consistency as a costume. Six pages write
// live and should keep writing live. What has to be the same everywhere is the
// VOCABULARY and the PROMISE behind each word — so a page says which of the
// four things it is doing, and the words mean one thing when it says them.

// ── The four states a setting can be in ─────────────────────────────────────
//
// Two independent facts, which is why four states and not two: WHERE the value
// currently is, and WHEN the machine picks it up.
var STATES = {
    live: {
        label: "Live",
        blurb: "Changes here take effect as you make them, and are saved."
    },
    staged: {
        label: "Staged",
        blurb: "Changes are held here until you apply them. Nothing has " +
               "changed on this machine yet."
    },
    applied: {
        label: "Applied",
        blurb: "This is on the machine now. It is not saved until you keep it."
    },
    saved: {
        label: "Saved",
        blurb: "Written where it survives a logout."
    }
}

// ── The four verbs, and the one difference that matters ─────────────────────
//
// Reset is the one six pages already used, and it is the one that is NOT about
// the user's own change — it goes back past every change to what the shell
// shipped with. Revert goes back one step, to what was there before this edit.
// Conflating them is how a user loses a year of settings by clicking the button
// that undoes the last thirty seconds.
var VERBS = {
    apply: {
        label: "Apply",
        blurb: "Make this real now, subject to confirmation."
    },
    save: {
        label: "Save",
        blurb: "Persist what is already real."
    },
    revert: {
        label: "Revert",
        blurb: "Put back what was there before."
    },
    reset: {
        label: "Reset",
        blurb: "Return to the shipped default."
    }
}

// ── Words a control may not be labelled with ────────────────────────────────
//
// Each of these is one of the four verbs above wearing a different name, and
// the tree had all three. A second word for an act the user already learned is
// worse than a missing one: it reads as a fifth thing that must do something
// else, so people click it to find out.
//
// Prose may still use them — "discard the draft" in a description is a
// sentence, not a promise. This list bounds LABELS.
var BANNED_LABELS = {
    "Discard":  "Revert — the draft is what was there before, so putting it back is Revert",
    "Undo":     "Revert",
    "Forget":   "Revert",
    "Restore":  "Reset, when it means the shipped default; Revert when it means the last value",
    "Commit":   "Save",
    "Write":    "Save"
}

// ── When a change reaches the machine ───────────────────────────────────────
//
// Criterion 1's fourth state. A control that does not take effect where the
// user changed it has to say so THERE, next to itself, and not in a release
// note. "now" is the default and renders nothing: a page that says "takes
// effect immediately" on every row has taught the reader to skip the line that
// matters.
var EFFECTS = {
    now:     "",
    relogin: "Takes effect at your next login.",
    reboot:  "Takes effect after a reboot.",
    apply:   "Takes effect when you apply the blueprint.",
    reload:  "Takes effect when the compositor reloads its configuration."
}

function stateLabel(state) {
    return STATES[state] ? STATES[state].label : ""
}

function stateBlurb(state) {
    return STATES[state] ? STATES[state].blurb : ""
}

function verbLabel(verb) {
    return VERBS[verb] ? VERBS[verb].label : ""
}

function verbBlurb(verb) {
    return VERBS[verb] ? VERBS[verb].blurb : ""
}

function effectNote(effect) {
    if (!effect) return ""
    return EFFECTS[effect] !== undefined ? EFFECTS[effect] : ""
}

// ── What the commit bar says it is holding ──────────────────────────────────
//
// One sentence, built in one place, so the count and the noun agree everywhere
// and nobody writes "1 unsaved changes" again.
function stagedLine(n, noun) {
    var word = noun || "change"
    if (n <= 0) return "Nothing staged"
    return n + " staged " + word + (n === 1 ? "" : "s")
}

// The half-sentence under it: what will happen, in the words of whichever verbs
// this page offers. Pages differ in which of the three they have, and the
// difference is the point — saying "Apply" on a page with no Apply button is
// how the vocabulary stops meaning anything.
function stagedHint(canApply, canSave) {
    if (canApply && canSave)
        return "Apply puts this on the machine and asks you to confirm. " +
               "Save writes it without touching anything."
    if (canApply)
        return "Apply puts this on the machine and saves it in one act."
    if (canSave)
        return "Save writes this. Applying it is a separate action."
    return "Revert puts back what was there before."
}

// ── The one place a page is allowed to differ ───────────────────────────────
//
// Where persisting and taking effect are the SAME write, there is no honest
// distinction between Apply and Save, and offering both would be two buttons
// for one act. Keybinds is that page: the file is the configuration, and
// writing it is what makes the shortcut work. The word is Apply — it is the
// one that promises the change becomes real — and the page says it also saved.
var APPLY_IS_ALSO_SAVE =
    "Applied and saved: for this setting the file is what the machine reads."

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        STATES: STATES,
        VERBS: VERBS,
        BANNED_LABELS: BANNED_LABELS,
        EFFECTS: EFFECTS,
        APPLY_IS_ALSO_SAVE: APPLY_IS_ALSO_SAVE,
        stateLabel: stateLabel,
        stateBlurb: stateBlurb,
        verbLabel: verbLabel,
        verbBlurb: verbBlurb,
        effectNote: effectNote,
        stagedLine: stagedLine,
        stagedHint: stagedHint
    }
