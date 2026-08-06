//
//  RecentCommitsIntegrationTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The commit history is parsed out of one very specific `git log` format. The
/// synthetic parser tests pin the shape; these run real Git and parse what it
/// actually writes, which is what catches the format drifting out from under
/// the parser — a failure that otherwise shows up as an empty history.
struct RecentCommitsIntegrationTests {
    private func makeRepository() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("git-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func git(_ args: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "Ada", "GIT_AUTHOR_EMAIL": "ada@example.com",
            "GIT_COMMITTER_NAME": "Ada", "GIT_COMMITTER_EMAIL": "ada@example.com",
        ]) { _, new in new }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Exactly the command the status snapshot runs.
    private func readHistory(in root: URL, limit: Int) -> [GitStatusModel.RecentCommit] {
        let log = GitCommand.run([
            "log", "-n", "\(limit)", "--decorate=short",
            "--pretty=format:%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1f%P%x1f%D",
            "--name-status", "-z",
        ], in: GitDirectory(root.path))
        #expect(log.status == 0)
        return GitStatusModel.parseRecentCommits(log.stdout)
    }

    @Test func realGitOutputParsesIntoCommitsAndFiles() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)

        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        // A space and a newline in a file name are both legal, and both would
        // split a row if the records were not NUL-delimited.
        try "two\n".write(
            to: root.appendingPathComponent("odd name.txt"), atomically: true, encoding: .utf8
        )
        try git(["add", "-A"], in: root)
        try git(["commit", "-qm", "Add two files"], in: root)

        try git(["mv", "a.txt", "renamed.txt"], in: root)
        try git(["commit", "-qm", "Rename a file"], in: root)

        let commits = readHistory(in: root, limit: 10)

        #expect(commits.count == 2)

        // Newest first.
        let rename = try #require(commits.first)
        #expect(rename.subject == "Rename a file")
        #expect(rename.author == "Ada")
        #expect(!rename.shortHash.isEmpty)
        #expect(rename.references.contains { $0.contains("HEAD") })
        // Git reports this as a rename only when it detects one; either way
        // the paths must line up rather than shift.
        #expect(rename.files.contains { $0.path == "renamed.txt" })

        let first = try #require(commits.last)
        #expect(first.subject == "Add two files")
        // A root commit has no parent, so nothing to diff it against.
        #expect(first.parentHash == nil)
        #expect(first.files.count == 2)
        #expect(first.files.contains { $0.path == "odd name.txt" })
        #expect(first.files.allSatisfy { $0.status == "A" })

        // The second commit's parent is the first — this is what a commit's
        // own diff is read against.
        #expect(rename.parentHash == first.hash)
    }

    /// The history asks for one more than the page so "is there more?" is free.
    @Test func theLimitBoundsWhatComesBack() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)

        for index in 1...5 {
            try "\(index)\n".write(
                to: root.appendingPathComponent("f\(index).txt"),
                atomically: true, encoding: .utf8
            )
            try git(["add", "-A"], in: root)
            try git(["commit", "-qm", "Commit \(index)"], in: root)
        }

        #expect(readHistory(in: root, limit: 3).count == 3)
        #expect(readHistory(in: root, limit: 100).count == 5)
    }
}
