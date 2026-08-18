// Pure logic behind the launcher's "?" answer mode: local arithmetic and the
// reading of a Wolfram|Alpha Short Answers reply. Kept out of the QML files so
// it can be exercised directly by tests/answer-test.js — the same file the
// shell loads, not a copy of it.

// Recursive-descent arithmetic parser. Keeping this local avoids executing
// launcher input as JavaScript or passing it through a shell.
// Returns { valid: false } or { valid: true, expression, formatted }.
function calculate(input) {
    var expression = String(input === undefined || input === null ? "" : input).trim()
    if (expression === "" || !/[0-9]/.test(expression))
        return { valid: false }

    var pos = 0
    function skipSpace() {
        while (pos < expression.length && /\s/.test(expression.charAt(pos))) pos++
    }
    function primary() {
        skipSpace()
        if (expression.charAt(pos) === "(") {
            pos++
            var grouped = addSubtract()
            skipSpace()
            if (expression.charAt(pos) !== ")") throw "missing close parenthesis"
            pos++
            return grouped
        }

        var start = pos
        var dots = 0
        while (pos < expression.length) {
            var c = expression.charAt(pos)
            if (c >= "0" && c <= "9") {
                pos++
            } else if (c === "." && dots === 0) {
                dots++
                pos++
            } else {
                break
            }
        }
        if (start === pos || expression.substring(start, pos) === ".") throw "number expected"
        return Number(expression.substring(start, pos))
    }
    function unary() {
        skipSpace()
        if (expression.charAt(pos) === "+") { pos++; return unary() }
        if (expression.charAt(pos) === "-") { pos++; return -unary() }
        return primary()
    }
    function power() {
        var value = unary()
        skipSpace()
        if (expression.charAt(pos) === "^") {
            pos++
            value = Math.pow(value, power())
        }
        return value
    }
    function multiplyDivide() {
        var value = power()
        while (true) {
            skipSpace()
            var op = expression.charAt(pos)
            if (op !== "*" && op !== "/" && op !== "%") return value
            pos++
            var rhs = power()
            if (op === "*") value *= rhs
            else if (op === "/") value /= rhs
            else value %= rhs
        }
    }
    function addSubtract() {
        var value = multiplyDivide()
        while (true) {
            skipSpace()
            var op = expression.charAt(pos)
            if (op !== "+" && op !== "-") return value
            pos++
            var rhs = multiplyDivide()
            value = op === "+" ? value + rhs : value - rhs
        }
    }

    try {
        var result = addSubtract()
        skipSpace()
        if (pos !== expression.length || !isFinite(result)) return { valid: false }
        var formatted = String(Number(result.toPrecision(12)))
        return { valid: true, expression: expression, formatted: formatted }
    } catch (e) {
        return { valid: false }
    }
}

// Reads `curl -w '\n%{http_code}'` output from the Short Answers API.
// The API answers with plain text and uses the status code for meaning: 501 is
// "understood, but no short answer exists", which curl reports as success.
// Returns { answer, error }; exactly one of them is non-empty.
function describeAnswer(raw) {
    var lines = String(raw === undefined || raw === null ? "" : raw).split("\n")
    var code  = lines.length > 0 ? lines[lines.length - 1].trim() : ""
    var body  = lines.slice(0, -1).join("\n").trim()

    if (code === "200")
        return body !== ""
            ? { answer: body, error: "" }
            : { answer: "", error: "Wolfram|Alpha returned an empty answer" }
    if (code === "501")
        return { answer: "", error: "Wolfram|Alpha has no short answer for that" }
    if (code === "403")
        return { answer: "", error: "Wolfram|Alpha rejected the AppID — check it in Settings → Misc" }
    if (code === "400")
        return { answer: "", error: "Wolfram|Alpha could not read that question" }
    if (code === "000" || code === "")
        return { answer: "", error: "No answer — Wolfram|Alpha is unreachable" }
    return { answer: "", error: "Wolfram|Alpha returned HTTP " + code }
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = { calculate: calculate, describeAnswer: describeAnswer }
