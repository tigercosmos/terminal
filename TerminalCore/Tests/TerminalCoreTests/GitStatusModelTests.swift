//
//  GitStatusModelTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The Git panel's entire contents come from parsing porcelain v2. Every path
/// in it is a repository's own, which is untrusted text — a name may hold a
/// space, a newline, or something that looks like a status record — and a
/// misparse shows up as a file listed under the wrong heading, or not at all.
struct GitStatusParsingTests {
    /// Porcelain v2 with `-z` is NUL-delimited precisely because a newline is
    /// legal in a path.
    private func status(_ records: [String]) -> GitStatusModel.StatusResult {
        GitStatusModel.parseStatus(records.joined(separator: "\0") + "\0")
    }

    // MARK: - Branch headers

    @Test func theBranchHeadersDescribeWhereHEADIs() {
        let result = status([
            "# branch.oid abc123",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
        ])
        #expect(result.hasHead)
        #expect(result.headOID == "abc123")
        #expect(result.branch == "main")
        #expect(result.upstream == "origin/main")
        #expect(result.ahead == 2)
        #expect(result.behind == 3)
    }

    // MARK: - Line counts

    /// The toolbar's +/− totals come from `git diff --numstat`, whose columns
    /// are tab-separated so a path may hold spaces.
    @Test func numstatColumnsAddUpAcrossFiles() {
        let totals = GitStatusModel.parseNumstat("3\t1\ta.txt\n12\t0\tsrc/my file.swift\n")

        #expect(totals.additions == 15)
        #expect(totals.deletions == 1)
    }

    /// Git writes `-` for both columns of a binary file. Those rows carry no
    /// line count and must not be read as zero-width text edits or crash the
    /// sum.
    @Test func aBinaryFileContributesNoLines() {
        let totals = GitStatusModel.parseNumstat("-\t-\tlogo.png\n4\t2\ta.txt\n")

        #expect(totals.additions == 4)
        #expect(totals.deletions == 2)
    }

    @Test func anEmptyDiffIsZero() {
        let totals = GitStatusModel.parseNumstat("")

        #expect(totals.additions == 0)
        #expect(totals.deletions == 0)
    }

    /// `git diff` never reports untracked files, so their lines are counted by
    /// reading them. A file that Git would call binary contributes nothing,
    /// and a final line without a trailing newline still counts.
    @Test func untrackedTextFilesAreCountedAndBinariesAreNot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("numstat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "a\nb\nc\n".write(to: root.appendingPathComponent("three.txt"),
                              atomically: true, encoding: .utf8)
        try "no trailing newline".write(to: root.appendingPathComponent("one.txt"),
                                        atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("blob.bin"))

        let entries = ["three.txt", "one.txt", "blob.bin"].map {
            GitStatusModel.Entry(path: $0, staged: "?", unstaged: "?")
        }
        let total = GitStatusModel.untrackedLineAdditions(for: entries, in: root.path)

        #expect(total == 4)
    }

    /// A porcelain path is repository text and may try to escape the root.
    @Test func anUntrackedPathOutsideTheRootIsIgnored() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("numstat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("escaped-\(UUID().uuidString).txt")
        try "x\ny\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let entry = GitStatusModel.Entry(
            path: "../\(outside.lastPathComponent)", staged: "?", unstaged: "?"
        )
        #expect(GitStatusModel.untrackedLineAdditions(for: [entry], in: root.path) == 0)
    }

    /// A repository with no commit yet reports `(initial)`, which is not an
    /// OID and must not be shown as one.
    @Test func anUnbornBranchHasNoHead() {
        let result = status(["# branch.oid (initial)", "# branch.head main"])
        #expect(!result.hasHead)
        #expect(result.headOID == nil)
    }

    @Test func aDetachedHeadIsNamedRatherThanShownAsABranch() {
        let result = status(["# branch.head (detached)"])
        #expect(result.branch == "detached HEAD")
    }

    // MARK: - Entries

    @Test func anOrdinaryChangeCarriesItsTwoStatusLetters() {
        let result = status(["1 MD N... 100644 100644 100644 aaa bbb src/main.swift"])
        #expect(result.entries.count == 1)
        let entry = result.entries[0]
        #expect(entry.path == "src/main.swift")
        #expect(entry.staged == "M")
        #expect(entry.unstaged == "D")
        #expect(!entry.isConflict)
    }

    /// The path is the last field and is not split further, so a name holding
    /// spaces arrives whole.
    @Test func aPathWithSpacesArrivesWhole() {
        let result = status(["1 M. N... 100644 100644 100644 aaa bbb my notes file.txt"])
        #expect(result.entries.map(\.path) == ["my notes file.txt"])
    }

    /// A rename's original path is the record *after* it, because `-z` cannot
    /// use the tab the human-readable format uses.
    ///
    /// The original path here is `? sneaky.txt`, a name a repository is free
    /// to contain and which also reads as an untracked-file record. It has to
    /// be consumed as the rename's other half rather than parsed again, or
    /// renaming such a file adds a row for a file that does not exist.
    @Test func aRenameConsumesTheRecordCarryingItsOriginalPath() {
        let result = status([
            "2 R. N... 100644 100644 100644 aaa bbb R100 new/name.txt",
            "? sneaky.txt",
            "1 .M N... 100644 100644 100644 ccc ddd other.txt",
        ])
        #expect(result.entries.count == 2)
        #expect(result.entries[0].path == "new/name.txt")
        #expect(result.entries[0].origPath == "? sneaky.txt")
        #expect(result.entries[0].staged == "R")
        #expect(result.entries[1].path == "other.txt")
    }

    /// A rename record with nothing after it is dropped rather than paired
    /// with whatever happens to follow.
    @Test func aTruncatedRenameRecordIsDropped() {
        let result = status(["2 R. N... 100644 100644 100644 aaa bbb R100 new/name.txt"])
        #expect(result.entries.isEmpty)
    }

    @Test func anUnmergedPathIsAConflict() {
        let result = status([
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc both.txt"
        ])
        #expect(result.entries.count == 1)
        #expect(result.entries[0].isConflict)
        #expect(result.entries[0].path == "both.txt")
    }

    @Test func untrackedAndIgnoredPathsAreKeptApart() {
        let result = status(["? new.txt", "! build/output.o"])
        #expect(result.entries.map(\.path) == ["new.txt"])
        #expect(result.entries[0].staged == "?")
        #expect(result.ignoredPaths == ["build/output.o"])
    }

    /// A repository's own file names reach this parser directly. A name that
    /// looks like a header, or holds a newline, must stay a path.
    @Test func aHostilePathIsStillJustAPath() {
        let result = status([
            "? # branch.head evil",
            "1 .M N... 100644 100644 100644 aaa bbb two\nline.txt",
        ])
        #expect(result.branch == nil)
        #expect(result.entries.map(\.path) == ["# branch.head evil", "two\nline.txt"])
    }

    /// A record whose shape does not match is skipped rather than guessed at.
    @Test func aMalformedRecordIsSkipped() {
        let result = status([
            "1 too-long-status N... 100644 100644 100644 aaa bbb file.txt",
            "1 M.",
            "9 unknown record type",
            "",
            "1 .M N... 100644 100644 100644 aaa bbb good.txt",
        ])
        #expect(result.entries.map(\.path) == ["good.txt"])
    }

    @Test func anEmptyStatusIsACleanRepository() {
        let result = GitStatusModel.parseStatus("")
        #expect(result.entries.isEmpty)
        #expect(result.ignoredPaths.isEmpty)
        #expect(result.branch == nil)
    }

    /// `git rm --cached` leaves a path in the worktree but not the index, and
    /// porcelain v2 then reports it twice — once staged-deleted, once
    /// untracked. Two rows for one path used to reach a decoration dictionary
    /// keyed by path and take the app down on every refresh.
    @Test func aPathRemovedFromTheIndexButStillOnDiskIsListedOnce() {
        let result = status([
            "1 D. N... 100644 000000 000000 aaa bbb kept.txt",
            "? kept.txt",
        ])
        #expect(result.entries.map(\.path) == ["kept.txt"])
        // Of the two rows Git reports, the staged deletion is the one kept:
        // tracked entries come first and it carries the more useful status.
        #expect(result.entries.first?.staged == "D")
        #expect(result.entries.first?.unstaged == ".")
    }

    // MARK: - Recent commits

    /// One record as `log --pretty=… --name-status -z` writes it: the header's
    /// seven US-separated fields, then the first file's status on the next
    /// line, then NUL-delimited paths and statuses.
    private func commitRecord(
        hash: String, short: String, subject: String, author: String,
        timestamp: String, parents: String, refs: String,
        files: [String] = []
    ) -> String {
        let header = [hash, short, subject, author, timestamp, parents, refs]
            .joined(separator: "\u{1f}")
        guard !files.isEmpty else { return header }
        return header + "\n" + files.joined(separator: "\u{0}")
    }

    /// Records are separated by RS and header fields by US. Subjects are safe
    /// to read up to the first newline because `%s` collapses the message's
    /// first paragraph onto one line — the newline in a record always belongs
    /// to the file rows that follow.
    @Test func recentCommitsComeBackInOrder() {
        let output = [
            commitRecord(
                hash: "abc1234567", short: "abc1234", subject: "First commit",
                author: "Ada", timestamp: "1700000000", parents: "", refs: ""
            ),
            commitRecord(
                hash: "def1234567", short: "def1234", subject: "Second commit",
                author: "Grace", timestamp: "1700000100",
                parents: "abc1234567", refs: "HEAD -> main, origin/main"
            ),
        ].joined(separator: "\u{1e}")
        let commits = GitStatusModel.parseRecentCommits("\u{1e}" + output)

        #expect(commits.count == 2)
        #expect(commits[0].shortHash == "abc1234")
        #expect(commits[0].subject == "First commit")
        #expect(commits[0].author == "Ada")
        // A root commit has no parent, so there is nothing to diff it against.
        #expect(commits[0].parentHash == nil)
        #expect(commits[1].hash == "def1234567")
        #expect(commits[1].subject == "Second commit")
        #expect(commits[1].parentHash == "abc1234567")
        #expect(commits[1].references == ["HEAD -> main", "origin/main"])
    }

    /// A merge lists every parent; the diff shown is against the first, which
    /// is the branch the history is being read down.
    @Test func onlyTheFirstParentIsKept() {
        let record = commitRecord(
            hash: "m1", short: "m1", subject: "Merge", author: "Ada",
            timestamp: "1700000000", parents: "p1 p2 p3", refs: ""
        )
        #expect(GitStatusModel.parseRecentCommits("\u{1e}" + record).first?.parentHash == "p1")
    }

    /// The file rows are where repository-authored paths arrive, which is why
    /// the records are NUL-delimited: a newline in a name must not split a row.
    @Test func fileRowsSurviveAwkwardPaths() {
        let record = commitRecord(
            hash: "abc", short: "abc", subject: "s", author: "a",
            timestamp: "1700000000", parents: "p", refs: "",
            files: ["M", "src/two words.swift", "A", "odd\nname.txt", "D", "gone.txt"]
        )
        let files = GitStatusModel.parseRecentCommits("\u{1e}" + record).first?.files ?? []

        #expect(files.count == 3)
        #expect(files[0].status == "M")
        #expect(files[0].path == "src/two words.swift")
        #expect(files[0].fileName == "two words.swift")
        #expect(files[0].directory == "src")
        #expect(files[1].path == "odd\nname.txt")
        #expect(files[2].status == "D")
    }

    /// A rename is one row carrying two paths. Reading it as two rows would
    /// shift every file after it onto the wrong status.
    @Test func aRenameCarriesBothOfItsPaths() {
        let record = commitRecord(
            hash: "abc", short: "abc", subject: "s", author: "a",
            timestamp: "1700000000", parents: "p", refs: "",
            files: ["R100", "old/name.swift", "new/name.swift", "M", "after.swift"]
        )
        let files = GitStatusModel.parseRecentCommits("\u{1e}" + record).first?.files ?? []

        #expect(files.count == 2)
        #expect(files[0].status == "R")
        #expect(files[0].originalPath == "old/name.swift")
        #expect(files[0].path == "new/name.swift")
        // The row after the rename still lines up with its own status.
        #expect(files[1].status == "M")
        #expect(files[1].path == "after.swift")
    }

    @Test func aCommitRecordWithMissingFieldsIsSkipped() {
        #expect(GitStatusModel.parseRecentCommits("abc\u{1f}abc").isEmpty)
        // A timestamp that is not a number is not a commit either.
        #expect(GitStatusModel.parseRecentCommits(
            "a\u{1f}b\u{1f}c\u{1f}d\u{1f}not-a-time\u{1f}p\u{1f}"
        ).isEmpty)
    }
}

/// The panel reads the markers Git leaves in a repository's own directory for
/// an interrupted operation, which no plumbing command reports. Getting this
/// wrong means the panel silently offers to commit in the middle of a rebase.
struct GitRepositoryOperationTests {
    @Test func aCleanRepositoryIsInNoOperation() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")
        let git = repository.directory.directory(repository.path(".git"))
        #expect(GitStatusModel.detectRepositoryOperation(gitDirectory: git) == nil)
    }

    @Test func anInterruptedMergeIsReported() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")
        try repository.write("merging\n", to: ".git/MERGE_HEAD")
        let git = repository.directory.directory(repository.path(".git"))
        #expect(GitStatusModel.detectRepositoryOperation(gitDirectory: git) != nil)
    }
}

/// A ref goes to Git on a command line. One that begins with `-` would be read
/// as an option instead of a revision, which is why nothing else in the
/// compare panel is allowed to skip this check.
struct GitCompareRefTests {
    @Test func aRefThatCouldBeReadAsAnOptionIsRefused() {
        #expect(!GitCompareModel.isSafeRef("--upload-pack=touch /tmp/pwned"))
        #expect(!GitCompareModel.isSafeRef("-x"))
        #expect(!GitCompareModel.isSafeRef(""))
        #expect(GitCompareModel.isSafeRef("main"))
        #expect(GitCompareModel.isSafeRef("HEAD~2"))
        #expect(GitCompareModel.isSafeRef("origin/main"))
    }

    @Test func aRevisionResolvesToItsCommit() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")

        let head = try #require(
            GitCompareModel.resolveCommit("HEAD", in: repository.directory)
        )
        #expect(head.count >= 40)
        #expect(head.allSatisfy { $0.isHexDigit })
        #expect(GitCompareModel.resolveCommit("main", in: repository.directory) == head)
    }

    @Test func aRevisionThatIsNotInTheRepositoryResolvesToNothing() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")
        #expect(GitCompareModel.resolveCommit("no-such-branch", in: repository.directory) == nil)
        #expect(GitCompareModel.resolveCommit("-x", in: repository.directory) == nil)
    }

    /// `^{commit}` is what rejects a tag pointing at something that is not a
    /// commit — comparing against a blob would ask Git for a diff it cannot
    /// give and read as an empty comparison.
    @Test func aTagPointingAtABlobIsNotARevision() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")

        let blob = repository.run("hash-object", "-w", repository.path("file.txt"))
        let oid = blob.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        repository.run("tag", "blob-tag", oid)
        #expect(GitCompareModel.resolveCommit("blob-tag", in: repository.directory) == nil)
    }
}

/// Blame decides what the editor's gutter says next to every line, and the
/// porcelain it parses is a repository's own commit metadata — an author name
/// is whatever someone typed into their config.
struct GitBlameTests {
    @Test func aPorcelainRecordBecomesALine() {
        let line = GitBlame.parsePorcelain("""
            abcdef1234567890 1 1 1
            author Ada Lovelace
            author-time 1700000000
            author-tz +0900
            summary Add the thing
            filename src/main.swift
            \tcontents
            """)
        #expect(line?.oid == "abcdef1234567890")
        #expect(line?.author == "Ada Lovelace")
        #expect(line?.summary == "Add the thing")
        #expect(line?.shortOID == "abcdef12")
    }

    @Test func aRecordWithNoAuthorSaysSoRatherThanShowingNothing() {
        let line = GitBlame.parsePorcelain("abcdef1234567890 1 1 1\nsummary x\n")
        #expect(line?.author.isEmpty == false)
    }

    @Test func nothingParsableIsNoLineAtAll() {
        #expect(GitBlame.parsePorcelain("") == nil)
        #expect(GitBlame.parsePorcelain("\n\n") == nil)
    }

    /// Git's sentinel OID for a line that is in no commit yet — the annotation
    /// has to say that rather than borrow the neighbouring commit's author.
    @Test func anUncommittedLineIsRecognized() {
        let line = GitBlame.parsePorcelain("0000000000000000000000000000000000000000 1 1 1\n")
        #expect(line?.isUncommitted == true)
        #expect(line?.inlineAnnotation.isEmpty == false)
    }

    /// The date is the commit's own wall clock, not the reader's, so it is
    /// stable wherever the tests happen to run.
    @Test func theDateIsShownInTheCommitsOwnTimeZone() {
        let line = GitBlame.parsePorcelain("""
            abcdef1234567890 1 1 1
            author Ada
            author-time 1700000000
            author-tz +0900
            summary x
            """)
        // 1700000000 is 2023-11-14 22:13:20Z, which is the 15th in +0900.
        #expect(line?.shortDate == "2023-11-15")
        #expect(line?.fullDate == "2023-11-15 07:13 +0900")
    }

    @Test func anUnparseableTimeZoneIsTreatedAsUTC() {
        let line = GitBlame.parsePorcelain("""
            abcdef1234567890 1 1 1
            author-time 1700000000
            author-tz nonsense
            """)
        #expect(line?.shortDate == "2023-11-14")
    }

    @Test func aLineWithNoTimeHasNoDate() {
        let line = GitBlame.parsePorcelain("abcdef1234567890 1 1 1\nauthor Ada\n")
        #expect(line?.shortDate.isEmpty == true)
        #expect(line?.fullDate.isEmpty == true)
    }

    /// A subject long enough to push the code off screen is cut, and the cut
    /// is marked.
    @Test func aLongSummaryIsShortenedInTheAnnotation() {
        let line = GitBlame.parsePorcelain("""
            abcdef1234567890 1 1 1
            author Ada
            author-time 1700000000
            author-tz +0000
            summary \(String(repeating: "x", count: 80))
            """)
        let annotation = line?.inlineAnnotation ?? ""
        #expect(annotation.hasSuffix("…"))
        #expect(annotation.count < 80)
    }
}
