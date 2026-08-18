#!/usr/bin/env node
// Tests the launcher's "?" answer logic against the file the shell actually
// loads (src/services/answer.js), not a copy of it.
//
//   node tests/answer-test.js

"use strict";

const path = require("path");
const Answer = require(path.join(__dirname, "..", "src", "services", "answer.js"));

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

// ── calculate() ──────────────────────────────────────────────────────────────
const value = (input) => {
    const r = Answer.calculate(input);
    return r.valid ? r.formatted : null;
};

check("integer arithmetic",        value("2+2"), "4");
check("precedence",                value("2+3*4"), "14");
check("parentheses",               value("(2+3)*4"), "20");
check("exponent is right-assoc",   value("2^3^2"), "512");
check("unary minus",               value("-4*2"), "-8");
check("decimals",                  value("0.1+0.2"), "0.3");
check("modulo",                    value("7%3"), "1");
check("whitespace tolerated",      value("  12 * 7  "), "84");
check("float rounding trimmed",    value("1/3"), "0.333333333333");

// Anything the parser cannot fully consume must fall through to Wolfram rather
// than be answered wrongly or half-parsed.
check("word query is not math",    value("density of aluminium*2"), null);
check("trailing garbage rejected", value("5 apples"), null);
check("empty rejected",            value(""), null);
check("no digits rejected",        value("hello"), null);
check("unbalanced paren rejected", value("(2+3"), null);
check("lone dot rejected",         value("."), null);
check("divide by zero rejected",   value("1/0"), null);
check("null input rejected",       value(null), null);
// The parser must never evaluate its input as JavaScript.
check("no JS evaluation",          value("1;process.exit(1)"), null);
check("no property access",        value("[].constructor"), null);

// ── describeAnswer() ─────────────────────────────────────────────────────────
check("200 returns the body",
      Answer.describeAnswer("5400 kg/m^3\n200"),
      { answer: "5400 kg/m^3", error: "" });
check("200 keeps internal newlines",
      Answer.describeAnswer("line one\nline two\n200"),
      { answer: "line one\nline two", error: "" });
check("200 with an empty body is an error",
      Answer.describeAnswer("\n200"),
      { answer: "", error: "Wolfram|Alpha returned an empty answer" });
check("501 has no short answer",
      Answer.describeAnswer("Wolfram|Alpha did not understand your input\n501"),
      { answer: "", error: "Wolfram|Alpha has no short answer for that" });
check("403 names the AppID",
      /AppID/.test(Answer.describeAnswer("Invalid appid\n403").error), true);
check("000 is reported as unreachable",
      /unreachable/.test(Answer.describeAnswer("\n000").error), true);
check("empty output is reported as unreachable",
      /unreachable/.test(Answer.describeAnswer("").error), true);
check("unknown code is surfaced verbatim",
      Answer.describeAnswer("gateway\n502").error, "Wolfram|Alpha returned HTTP 502");

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
