//
//  CompareFilterTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The filter's promise is that its syntax is the one a search panel's "files
/// to include" field already taught the user. These tests pin that syntax down
/// case by case, since the only other way to tell whether a glob matched is to
/// open a repository and count rows.
struct CompareFilterTests {
    private func matches(_ pattern: String, _ path: String) -> Bool {
        guard let matcher = CompareFilterCompiler.GlobMatcher(pattern) else {
            Issue.record("\(pattern) compiled to no matcher")
            return false
        }
        return matcher.matches(path)
    }

    // MARK: - Comma splitting

    /// Without top-level-only splitting, `*.{ts,tsx}` would split into `*.{ts`
    /// and `tsx}` and match nothing.
    @Test func aCommaInsideBraceAlternationIsNotASeparator() {
        #expect(CompareFilterCompiler.splitTopLevelCommas("*.{ts,tsx}") == ["*.{ts,tsx}"])
        #expect(
            CompareFilterCompiler.splitTopLevelCommas("*.{ts,tsx}, src/**")
                == ["*.{ts,tsx}", " src/**"]
        )
    }

    @Test func aBackslashEscapesTheCharacterAfterIt() {
        #expect(CompareFilterCompiler.splitTopLevelCommas("a\\,b,c") == ["a\\,b", "c"])
    }

    /// An unbalanced brace must not make the rest of the list vanish into a
    /// group that never closes.
    @Test func anUnbalancedClosingBraceDoesNotDrivDepthNegative() {
        #expect(CompareFilterCompiler.splitTopLevelCommas("}a,b") == ["}a", "b"])
    }

    // MARK: - Expansion

    @Test func aTrailingSlashMeansEverythingInsideThatFolder() {
        #expect(CompareFilterCompiler.expand("src/") == "src/**")
        #expect(matches("src/", "src/app/main.swift"))
        #expect(!matches("src/", "lib/main.swift"))
    }

    /// A bare segment is the common case — someone types `node_modules` and
    /// means "anywhere in the tree", not "at the root".
    @Test func aBareSegmentMatchesAnywhereInTheTree() {
        #expect(matches("node_modules", "node_modules"))
        #expect(matches("node_modules", "web/node_modules/react/index.js"))
        #expect(matches("README.md", "docs/README.md"))
        #expect(!matches("README.md", "docs/README.mdx"))
    }

    @Test func aPatternWithAWildcardIsNotExpandedAsABareSegment() {
        #expect(CompareFilterCompiler.expand("*.ts") == "*.ts")
        #expect(CompareFilterCompiler.expand("src/main.swift") == "src/main.swift")
    }

    // MARK: - Glob semantics

    /// A slashless wildcard would otherwise silently miss everything in a
    /// subdirectory, which reads as a broken filter rather than a strict one.
    @Test func aSlashlessPatternAlsoMatchesALastComponent() {
        #expect(matches("*.ts", "index.ts"))
        #expect(matches("*.ts", "src/app/index.ts"))
        #expect(matches("**/*.ts", "src/app/index.ts"))
    }

    @Test func oneStarStopsAtASeparatorAndTwoStarsCrossIt() {
        #expect(matches("src/*.ts", "src/index.ts"))
        #expect(!matches("src/*.ts", "src/app/index.ts"))
        #expect(matches("src/**/*.ts", "src/app/deep/index.ts"))
    }

    /// `**/` also stands for no directory at all, so `**/foo.ts` matches a
    /// `foo.ts` sitting at the root.
    @Test func aLeadingDoubleStarMayMatchNoDirectory() {
        #expect(matches("**/foo.ts", "foo.ts"))
        #expect(matches("**/foo.ts", "a/b/foo.ts"))
    }

    @Test func aQuestionMarkIsOneNonSeparatorCharacter() {
        #expect(matches("src/?.ts", "src/a.ts"))
        #expect(!matches("src/?.ts", "src/ab.ts"))
        #expect(!matches("a?c", "a/c"))
    }

    @Test func braceAlternationOffersEachBranch() {
        #expect(matches("*.{ts,tsx}", "index.tsx"))
        #expect(matches("*.{ts,tsx}", "index.ts"))
        #expect(!matches("*.{ts,tsx}", "index.js"))
    }

    /// The pattern is anchored, so a glob never matches a path that merely
    /// contains it.
    @Test func aGlobIsAnchoredAtBothEnds() {
        #expect(!matches("src/*.ts", "vendor/src/index.ts"))
        #expect(!matches("*.ts", "index.ts.bak"))
    }

    /// A path is untrusted text — it comes out of whatever repository was
    /// opened — so regex metacharacters in it must stay literal.
    @Test func regexMetacharactersInAPathStayLiteral() {
        #expect(matches("a.b", "a.b"))
        #expect(!matches("a.b", "axb"))
        #expect(matches("*.(x)", "weird.(x)"))
    }

    @Test func aListMatchesWhenAnyPatternDoes() {
        #expect(matches("*.ts, *.swift", "main.swift"))
        #expect(matches("*.ts, *.swift", "main.ts"))
        #expect(!matches("*.ts, *.swift", "main.rs"))
    }

    /// Nil means "no filter", so the caller can skip the test entirely rather
    /// than run every path through a matcher that accepts nothing.
    @Test func anEmptyOrUnusableListCompilesToNoMatcher() {
        #expect(CompareFilterCompiler.GlobMatcher("") == nil)
        #expect(CompareFilterCompiler.GlobMatcher("   ,  ,") == nil)
    }

    /// One unparseable pattern must not poison the rest of the list — an
    /// unclosed brace in one entry still leaves the others filtering.
    @Test func anUnparseablePatternIsSkippedRatherThanFailingTheList() {
        #expect(matches("*.ts, {a", "main.ts"))
        // …and a list of nothing but unparseable patterns is no filter at all,
        // rather than one that rejects every path.
        #expect(CompareFilterCompiler.GlobMatcher("{a") == nil)
    }

    // MARK: - Content search

    @Test func anEmptyQueryIsNoSearchAtAll() {
        var filter = CompareFilter()
        filter.include = "*.ts"
        #expect(filter.isActive)
        #expect(!filter.hasQuery)
        guard case .none = CompareFilterCompiler.search(filter) else {
            Issue.record("an empty query should compile to no matcher")
            return
        }
    }

    @Test func aPlainQueryIsLiteralTextRatherThanAPattern() throws {
        var filter = CompareFilter()
        filter.query = "a.b"
        let regex = try #require(matcher(for: filter))
        #expect(found(regex, in: "a.b"))
        #expect(!found(regex, in: "axb"))
    }

    @Test func theRegexToggleTurnsTheQueryIntoAPattern() throws {
        var filter = CompareFilter()
        filter.query = "a.b"
        filter.useRegex = true
        let regex = try #require(matcher(for: filter))
        #expect(found(regex, in: "axb"))
    }

    @Test func anUnparseableRegexIsReportedRatherThanSilentlyMatchingNothing() {
        var filter = CompareFilter()
        filter.query = "("
        filter.useRegex = true
        guard case .invalid(let message) = CompareFilterCompiler.search(filter) else {
            Issue.record("an unparseable pattern should report why")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func matchingIsCaseInsensitiveUntilTheToggleIsOn() throws {
        var filter = CompareFilter()
        filter.query = "todo"
        #expect(found(try #require(matcher(for: filter)), in: "TODO: fix"))
        filter.matchCase = true
        #expect(!found(try #require(matcher(for: filter)), in: "TODO: fix"))
    }

    /// `\b` only fires at a word/non-word transition, so it never matches
    /// before `.` or after `+`. Whole-word uses lookarounds instead, which is
    /// what lets `.env` and `C++` match on their own.
    @Test func wholeWordWorksForQueriesThatStartOrEndInPunctuation() throws {
        var filter = CompareFilter()
        filter.wholeWord = true

        filter.query = ".env"
        let dotEnv = try #require(matcher(for: filter))
        #expect(found(dotEnv, in: "read .env now"))
        #expect(!found(dotEnv, in: "read .envrc now"))

        filter.query = "C++"
        #expect(found(try #require(matcher(for: filter)), in: "in C++ code"))

        filter.query = "log"
        let log = try #require(matcher(for: filter))
        #expect(found(log, in: "the log file"))
        #expect(!found(log, in: "the login file"))
    }

    /// The boundaries bind to the whole pattern, not to the first and last
    /// alternative — otherwise `foo|bar` would only guard `foo`'s left side.
    @Test func wholeWordBindsToTheWholeAlternation() throws {
        var filter = CompareFilter()
        filter.query = "foo|bar"
        filter.useRegex = true
        filter.wholeWord = true
        let regex = try #require(matcher(for: filter))
        #expect(found(regex, in: "a bar here"))
        #expect(!found(regex, in: "a barn here"))
        #expect(!found(regex, in: "a foobar here"))
    }

    /// A search runs over a whole file, so `^` and `$` have to mean "a line"
    /// rather than "the blob".
    @Test func anchorsMatchEachLineOfTheContent() throws {
        var filter = CompareFilter()
        filter.query = "^b$"
        filter.useRegex = true
        #expect(found(try #require(matcher(for: filter)), in: "a\nb\nc"))
    }

    // MARK: - Helpers

    private func matcher(for filter: CompareFilter) -> NSRegularExpression? {
        guard case .matcher(let regex) = CompareFilterCompiler.search(filter) else {
            return nil
        }
        return regex
    }

    private func found(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(
            in: text, options: [], range: NSRange(text.startIndex..., in: text)
        ) != nil
    }
}

struct CompareFilterStateTests {
    @Test func aFilterIsInactiveUntilSomethingIsTypedIntoIt() {
        var filter = CompareFilter()
        #expect(!filter.isActive)
        #expect(!filter.hasQuery)

        filter.exclude = "node_modules"
        #expect(filter.isActive)
        #expect(!filter.hasQuery)
    }

    /// Whitespace alone is not a query — the toggles below it would otherwise
    /// look armed while nothing is being searched for.
    @Test func aQueryOfOnlyWhitespaceIsNotAQuery() {
        var filter = CompareFilter()
        filter.query = "   "
        #expect(filter.isActive)
        #expect(!filter.hasQuery)
    }
}
