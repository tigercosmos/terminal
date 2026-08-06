//
//  GitCommandTimeoutTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Every panel runs Git synchronously on a background task and waits for it.
/// A Git that never returns — a disconnected volume, a credential helper
/// waiting on a prompt, a repository whose lock is never released — used to
/// leave the panel spinning for the rest of the session. These pin the way out.
struct GitCommandTimeoutTests {
    /// A repository whose only unusual property is an alias that never
    /// returns. `exec` with redirections means the sleeping process does not
    /// inherit Git's pipes, so killing Git really does end the read.
    private func hangingRepository() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("git-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q"]
        git.currentDirectoryURL = root
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        return root
    }

    private let hangingAlias = "alias.hang=!exec sleep 45 </dev/null >/dev/null 2>&1"

    /// The point of the whole mechanism: come back, and say why.
    @Test func aGitThatNeverReturnsIsGivenUpOn() throws {
        let root = try hangingRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        let result = GitCommand.run(
            ["-c", hangingAlias, "hang"],
            in: GitDirectory(root.path),
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.status == GitCommand.timedOutStatus)
        #expect(result.stderr.contains("did not respond"))
        // The command would have taken 45s. Anything near that means the wait
        // was never bounded, or the reader threads outlived the process.
        #expect(elapsed < 15)
    }

    /// The timeout must not become a ceiling on ordinary commands: a fast
    /// command reports its own status, not the giving-up one.
    @Test func aCommandThatAnswersIsUnaffected() throws {
        let root = try hangingRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = GitCommand.run(
            ["rev-parse", "--show-toplevel"], in: GitDirectory(root.path), timeout: 30
        )

        #expect(result.status == 0)
        #expect(!result.stdout.isEmpty)
        #expect(!result.stderr.contains("did not respond"))
    }

    /// Without a timeout the behaviour is what it always was — callers that
    /// have their own deadline, or run commands that cannot hang, opt out.
    @Test func omittingTheTimeoutStillWaits() throws {
        let root = try hangingRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = GitCommand.run(["rev-parse", "--is-inside-work-tree"], in: GitDirectory(root.path))

        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }
}
