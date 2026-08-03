//
//  CompareFilter.swift
//  TerminalCore
//

import Foundation

/// Narrowing for the compare list: comma-separated include/exclude globs plus a
/// content search with match-case, whole-word, and regex toggles.
///
/// The syntax deliberately mirrors a search panel's "files to include" /
/// "files to exclude" fields, because that is the syntax someone reaching for
/// this filter already knows.
public struct CompareFilter: Equatable {
    public var query = ""
    public var matchCase = false
    public var wholeWord = false
    public var useRegex = false
    public var include = ""
    public var exclude = ""

    public init() {}

    public var isActive: Bool {
        !query.isEmpty || !include.isEmpty || !exclude.isEmpty
    }

    public var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Compiles a filter's glob and search inputs into matchers.
public enum CompareFilterCompiler {
    /// A compiled include/exclude list. Nil means "no filter", so a caller can
    /// skip the test entirely.
    public struct GlobMatcher {
        private let expressions: [NSRegularExpression]

        public init?(_ input: String) {
            let patterns = CompareFilterCompiler.splitTopLevelCommas(input)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !patterns.isEmpty else { return nil }
            let compiled = patterns.compactMap { pattern -> NSRegularExpression? in
                // A pattern that will not parse is skipped rather than
                // poisoning the whole list.
                try? NSRegularExpression(
                    pattern: CompareFilterCompiler.regexSource(
                        forGlob: CompareFilterCompiler.expand(pattern)
                    )
                )
            }
            guard !compiled.isEmpty else { return nil }
            expressions = compiled
        }

        public func matches(_ path: String) -> Bool {
            let range = NSRange(path.startIndex..., in: path)
            return expressions.contains {
                $0.firstMatch(in: path, options: [], range: range) != nil
            }
        }
    }

    public enum SearchResult {
        case none
        case matcher(NSRegularExpression)
        case invalid(String)
    }

    /// Compiles the query and its toggles the way a search panel does: literal
    /// text unless the regex toggle is on, wrapped in word boundaries when
    /// whole-word is on, case-insensitive unless match-case is on.
    public static func search(_ filter: CompareFilter) -> SearchResult {
        let query = filter.query
        guard !query.isEmpty else { return .none }
        var body = filter.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if filter.wholeWord {
            // Lookarounds rather than `\b`, so a query that starts or ends with
            // a non-word character (`.env`, `C++`, `foo.`) still matches on its
            // own — `\b` only fires at a word/non-word transition, so it never
            // matches before `.` or after `+`. The non-capturing group makes the
            // boundaries bind to the whole pattern rather than to the first and
            // last alternative of something like `foo|bar`.
            body = "(?<!\\w)(?:\(body))(?!\\w)"
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !filter.matchCase { options.insert(.caseInsensitive) }
        do {
            return .matcher(try NSRegularExpression(pattern: body, options: options))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// Splits on commas only at the *top* level: a comma inside `{a,b}` brace
    /// alternation is part of the glob, not a separator. Without this,
    /// `*.{ts,tsx}` would split into `*.{ts` and `tsx}` and match nothing.
    /// A backslash escapes the character after it.
    public static func splitTopLevelCommas(_ input: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        var iterator = input.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            switch character {
            case "\\":
                current.append(character)
                if let escaped = iterator.next() { current.append(escaped) }
            case "{":
                depth += 1
                current.append(character)
            case "}":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                out.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        out.append(current)
        return out
    }

    /// Applies the sugar a search panel's include/exclude fields have.
    public static func expand(_ pattern: String) -> String {
        // `src/` — everything inside that folder.
        if pattern.hasSuffix("/") { return pattern + "**" }
        // A bare segment such as `node_modules` or `README.md` matches
        // anywhere in the tree rather than only at the root.
        if !pattern.contains("/"), !pattern.contains("*"), !pattern.contains("?") {
            return "{\(pattern),**/\(pattern),\(pattern)/**,**/\(pattern)/**}"
        }
        return pattern
    }

    /// Translates a glob into an anchored regular expression.
    ///
    /// `**` crosses path separators and `*` does not, `?` is a single
    /// non-separator character, and `{a,b}` is alternation. A pattern with no
    /// separator in it also matches against a path's last component, so `*.ts`
    /// and `**/*.ts` behave the same — otherwise a slashless wildcard would
    /// silently miss everything in a subdirectory.
    public static func regexSource(forGlob glob: String) -> String {
        let body = translate(glob)
        let hasSeparator = glob.contains("/")
        return hasSeparator ? "^(?:\(body))$" : "^(?:.*/)?(?:\(body))$"
    }

    private static func translate(_ glob: String) -> String {
        var out = ""
        let characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 1
                if index < characters.count {
                    out += NSRegularExpression.escapedPattern(for: String(characters[index]))
                }
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    // `**/` may also stand for no directory at all, so
                    // `**/foo.ts` matches a `foo.ts` at the root.
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        index += 1
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "{":
                out += "(?:"
            case "}":
                out += ")"
            case ",":
                out += "|"
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return out
    }
}
