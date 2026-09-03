import QtQuick
import "../answer.js" as Answer
import "../search.js" as Search

// CalcProvider — arithmetic and unit conversion, offline, on a plain query.
//
// §15's example list has "2.5 GB -> MB" next to "Firefox", so both have to work
// in the same box with no prefix. That is the whole reason this is a provider
// rather than an extension of the "?" mode: "?" is the Wolfram|Alpha path, it
// leaves the machine, and it must stay something the user asks for explicitly.
//
// So: `answer.js`'s recursive-descent parser first (it is instant, offline and
// spends no API quota), then `search.js`'s converter. Neither can reach the
// network and neither is reachable from "?", which SearchService routes to
// nobody.
//
// A valid answer scores above every tier the matcher can produce, which is not
// a thumb on the scale: if the thing you typed IS an arithmetic expression, no
// application name is a better answer to it.

QtObject {
    id: p

    property var    api:   null
    property string query: ""

    readonly property var _parsed: Search.parseQuery(p.query)
    readonly property string _term: p.query === "" ? "" : p._parsed.term

    // Only when the whole term parses. A partial expression — "2 +" while the
    // user is still typing — is not an answer and must not push the app they
    // are also half-way through typing off the top of the list.
    readonly property var _calc: p._term === "" ? ({ valid: false })
                                                : Answer.calculate(p._term)
    readonly property var _conv: p._term === "" ? ({ valid: false })
                                                : Search.convert(p._term)

    readonly property var results: {
        if (p._term === "")
            return []
        if (p._conv.valid)
            return [{ "name": p._conv.expression + "  =  " + p._conv.formatted,
                      "detail": "Unit conversion · Enter copies the result",
                      "glyph": "󰑖",
                      "payload": p._conv.formatted,
                      "score": Search.TIER.EXACT + 200 }]
        if (p._calc.valid)
            return [{ "name": p._calc.expression + "  =  " + p._calc.formatted,
                      "detail": "Calculator · Enter copies the result",
                      "glyph": "󰃬",
                      "payload": p._calc.formatted,
                      "score": Search.TIER.EXACT + 200 }]
        return []
    }
}
