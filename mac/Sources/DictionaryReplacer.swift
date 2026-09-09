import Foundation

/// Deterministic dictionary post-pass, a port of applyReplacements in worker/src/dictionary.ts:
/// case-insensitive, word-boundary safe, tolerant of joined or hyphenated multi-word terms,
/// longest term wins, single left-to-right scan so replacements never cascade.
enum DictionaryReplacer {
    static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        guard !text.isEmpty else { return text }
        let replaceable = entries
            .map(\.wire)
            .filter { !$0.term.isEmpty && $0.replacement != nil }
            .sorted { $0.term.count > $1.term.count }
        guard !replaceable.isEmpty else { return text }

        let compiled: [(exact: NSRegularExpression, replacement: String)] = replaceable.compactMap { entry in
            guard let exact = try? NSRegularExpression(pattern: "^(?:\(pattern(for: entry.term)))$", options: [.caseInsensitive]),
                  let replacement = entry.replacement
            else { return nil }
            return (exact, replacement)
        }
        guard let combined = try? NSRegularExpression(
            pattern: replaceable.map { pattern(for: $0.term) }.joined(separator: "|"),
            options: [.caseInsensitive]
        ) else { return text }

        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in combined.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let hit = ns.substring(with: match.range)
            let hitRange = NSRange(location: 0, length: (hit as NSString).length)
            if let entry = compiled.first(where: { $0.exact.firstMatch(in: hit, range: hitRange) != nil }) {
                out += entry.replacement
            } else {
                out += hit
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Same shape as termPattern() in the Worker.
    static func pattern(for term: String) -> String {
        let words = term.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = words.joined(separator: "[\\s\\u00a0-]*")
        let wordish: (Character?) -> Bool = { c in
            guard let c else { return false }
            return c.isLetter || c.isNumber
        }
        let leading = wordish(term.first) ? "(?<![\\p{L}\\p{N}])" : ""
        let trailing = wordish(term.last) ? "(?![\\p{L}\\p{N}])" : ""
        return "\(leading)(?:\(body))\(trailing)"
    }
}
