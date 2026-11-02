//
//  KeroCodexThreadTests.swift
//  TerminalCore
//

import Darwin
import Foundation
import Testing

@testable import TerminalCore

/// A Codex TUI's threads live in a shared daemon, so a pane is matched to its
/// conversation by directory and start time. A wrong match resumes another
/// pane's conversation after a relaunch, which is worse than resuming none.
struct KeroCodexThreadTests {
    private let first = "01a19b1d-988e-7941-a3da-7f0793e408d8"
    private let second = "01a19b0f-a618-75a0-b9f3-3595631ba67e"
    private let third = "019a2b3c-4d5e-7f60-8172-93a4b5c6d7e8"

    // MARK: - Locating threads

    @Test func codexHomeHonorsTheOverride() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        #expect(KeroAgentResume.codexHomeURL(homeURL: home, environment: [:]).path
            == "/Users/me/.codex")
        #expect(KeroAgentResume.codexHomeURL(
            homeURL: home, environment: ["CODEX_HOME": "/opt/codex"]
        ).path == "/opt/codex")
        #expect(KeroAgentResume.codexHomeURL(
            homeURL: home, environment: ["CODEX_HOME": ""]
        ).path == "/Users/me/.codex")
    }

    @Test func liveThreadsAreTheLockFilesAndNothingElse() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let locks = home.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        for name in [
            "\(first).lock", "\(second.uppercased()).lock", "\(third).lock.tmp",
            "not-a-uuid.lock", ".DS_Store", third,
        ] {
            try Data().write(to: locks.appendingPathComponent(name))
        }
        #expect(KeroAgentResume.codexLiveThreadIDs(codexHome: home) == [second, first].sorted())
        #expect(KeroAgentResume.codexLiveThreadIDs(
            codexHome: home.appendingPathComponent("missing")
        ).isEmpty)
    }

    @Test func theRolloutIsFoundInTheNewestDayBySuffix() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let older = try writeRollout(home: home, day: "2026/10/31", id: first)
        let newer = try writeRollout(home: home, day: "2026/11/02", id: first)
        _ = try writeRollout(home: home, day: "2026/11/02", id: second)
        // A same-named file outside `sessions` is not a rollout.
        let stray = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data().write(to: stray.appendingPathComponent(
            "rollout-2026-11-02T09-00-00-\(third).jsonl"
        ))
        // A stray non-date directory does not derail the search.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions/notes"), withIntermediateDirectories: true
        )

        #expect(KeroAgentResume.codexRolloutURL(threadID: first.uppercased(), codexHome: home)
            == newer)
        #expect(older != newer)
        #expect(KeroAgentResume.codexRolloutURL(threadID: third, codexHome: home) == nil)
        #expect(KeroAgentResume.codexRolloutURL(threadID: "../x", codexHome: home) == nil)
    }

    // MARK: - Reading the header

    /// The header is read from a bounded prefix: the line after it is the
    /// conversation, and here it is not even JSON.
    @Test func theHeaderIsReadWithoutTheRestOfTheFile() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeRollout(
            home: home, day: "2026/11/02", id: first, cwd: "/Users/me/terminal",
            timestamp: "2026-11-02T07:05:54.248Z", originator: "codex-tui",
            trailing: String(repeating: "x", count: 4 * 1024 * 1024)
        )
        let thread = try #require(KeroAgentResume.codexThread(id: first, rolloutURL: url))
        #expect(thread.id == first)
        #expect(thread.cwd == "/Users/me/terminal")
        #expect(thread.originator == "codex-tui")
        #expect(thread.rolloutPath == url.path)
        // Fractional seconds survive; the parse rounds below a millisecond.
        #expect(abs(thread.createdAt.timeIntervalSince1970 - 1_793_603_154.248) < 0.001)
    }

    @Test func aHeaderWithoutATimestampFallsBackToTheFile() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeRollout(home: home, day: "2026/11/02", id: first, timestamp: nil)
        let thread = try #require(KeroAgentResume.codexThread(id: first, rolloutURL: url))
        #expect(abs(thread.createdAt.timeIntervalSinceNow) < 60)
    }

    @Test func aHeaderForAnotherThreadOrOfAnotherKindIsRejected() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeRollout(home: home, day: "2026/11/02", id: first)
        #expect(KeroAgentResume.codexThread(id: second, rolloutURL: url) == nil)

        let notMeta = home.appendingPathComponent("turn.jsonl")
        try Data((#"{"type":"turn_context","payload":{"id":"\#(first)","cwd":"/x"}}"#
            + "\n").utf8).write(to: notMeta)
        #expect(KeroAgentResume.codexThread(id: first, rolloutURL: notMeta) == nil)

        let noCwd = home.appendingPathComponent("nocwd.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"\#(first)"}}"# + "\n").utf8)
            .write(to: noCwd)
        #expect(KeroAgentResume.codexThread(id: first, rolloutURL: noCwd) == nil)
    }

    /// The read is bounded; a header that does not end inside it is not
    /// guessed at from a truncated line.
    @Test func aHeaderLongerThanTheReadIsNotParsed() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeRollout(
            home: home, day: "2026/11/02", id: first,
            instructions: String(repeating: "y", count: 70 * 1024)
        )
        #expect(KeroAgentResume.codexThread(id: first, rolloutURL: url) == nil)
    }

    @Test func liveThreadsComposeLocksRolloutsAndHeaders() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let locks = home.appendingPathComponent("thread-writer-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        // `second` is live but its rollout is missing; `third` has a rollout
        // but no lock, so it is finished.
        for id in [first, second] {
            try Data().write(to: locks.appendingPathComponent("\(id).lock"))
        }
        _ = try writeRollout(home: home, day: "2026/11/02", id: first, cwd: "/a")
        _ = try writeRollout(home: home, day: "2026/11/02", id: third, cwd: "/b")

        let threads = KeroAgentResume.codexLiveThreads(codexHome: home)
        #expect(threads.map(\.id) == [first])
        #expect(threads.first?.cwd == "/a")
        let reference = try #require(threads.first.map(KeroAgentResume.reference(for:)))
        #expect(reference.kind == .codex)
        #expect(reference.sessionID == first)
        #expect(reference.transcriptPath == threads.first?.rolloutPath)
    }

    /// A FIFO under the rollout's name would block an ordinary open until
    /// some writer appeared; the header read has to give up instead.
    @Test func aFIFOInPlaceOfTheRolloutIsNotRead() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions/2026/11/02", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("rollout-2026-11-02T07-05-54-\(first).jsonl")
        try #require(mkfifo(fifo.path, 0o600) == 0)

        #expect(KeroAgentResume.codexRolloutURL(threadID: first, codexHome: home) == fifo)
        #expect(KeroAgentResume.codexThread(id: first, rolloutURL: fifo) == nil)
    }

    @Test func theRolloutsModificationTimeIsRecorded() throws {
        let home = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try writeRollout(home: home, day: "2026/10/01", id: first)
        let written = Date(timeIntervalSince1970: 1_793_700_000)
        try FileManager.default.setAttributes(
            [.modificationDate: written], ofItemAtPath: url.path
        )
        let thread = try #require(KeroAgentResume.codexThread(id: first, rolloutURL: url))
        #expect(thread.modifiedAt == written)
        #expect(thread.createdAt < written)
    }

    // MARK: - Attribution

    private let start = Date(timeIntervalSince1970: 1_793_600_000)

    @Test func onlyAThreadInThePanesDirectoryIsAttributed() {
        let threads = [thread(first, cwd: "/other", after: 5)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/repo", startedAt: start, claimed: []
        ) == nil)
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/other/", startedAt: start, claimed: []
        )?.id == first)
    }

    /// A thread created before the TUI started belongs to some other
    /// process, apart from the clock slack between the two timestamps.
    @Test func aThreadOlderThanTheTUIIsNotItsOwn() {
        let justBefore = [thread(first, cwd: "/repo", after: -1.5)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: justBefore, cwd: "/repo", startedAt: start, claimed: []
        )?.id == first)
        let tooOld = [thread(first, cwd: "/repo", after: -2.5)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: tooOld, cwd: "/repo", startedAt: start, claimed: []
        ) == nil)
    }

    /// `codex resume <id>` keeps the thread's original creation time, but
    /// the resume and every turn after it write to the rollout.
    @Test func anOldThreadWrittenSinceTheTUIStartedIsItsOwn() {
        let resumed = [thread(first, cwd: "/repo", after: -86_400, modifiedAfter: 30)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: resumed, cwd: "/repo", startedAt: start, claimed: []
        )?.id == first)
    }

    /// An old thread that nobody has written since before the TUI started
    /// is some other, idle session that merely still holds its lock.
    @Test func anOldThreadUntouchedSinceBeforeTheTUIStartedIsNot() {
        let idle = [thread(first, cwd: "/repo", after: -86_400, modifiedAfter: -60)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: idle, cwd: "/repo", startedAt: start, claimed: []
        ) == nil)
    }

    /// Ordering stays by creation: a resumed old thread written a moment ago
    /// still comes before a thread created after the TUI started.
    @Test func theOldestByCreationWinsEvenWhenItWasWrittenLast() {
        let threads = [
            thread(second, cwd: "/repo", after: 10),
            thread(first, cwd: "/repo", after: -86_400, modifiedAfter: 60),
        ]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/repo", startedAt: start, claimed: []
        )?.id == first)
    }

    @Test func theOldestUnclaimedThreadWins() {
        let threads = [
            thread(first, cwd: "/repo", after: 30),
            thread(second, cwd: "/repo", after: 10),
            thread(third, cwd: "/repo", after: 20),
        ]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/repo", startedAt: start, claimed: []
        )?.id == second)
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/repo", startedAt: start, claimed: [second]
        )?.id == third)
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: "/repo", startedAt: start, claimed: [first, second, third]
        ) == nil)
    }

    /// Codex records the resolved `/private/tmp` where the shell reports
    /// `/tmp`; they are the same directory.
    @Test func aSymlinkedDirectoryMatchesItsTarget() throws {
        let directory = "/tmp/codex-attribution-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let threads = [thread(first, cwd: "/private" + directory, after: 1)]
        #expect(KeroAgentResume.attributeCodexThread(
            threads: threads, cwd: directory, startedAt: start, claimed: []
        )?.id == first)
    }

    // MARK: - Process start

    @Test func thisProcessStartedWithinTheLastDay() throws {
        let started = try #require(processStartDate(pid: getpid()))
        #expect(started <= Date())
        #expect(started > Date().addingTimeInterval(-86_400))
        #expect(processStartDate(pid: 0) == nil)
    }

    // MARK: - Helpers

    private func thread(
        _ id: String, cwd: String, after seconds: TimeInterval,
        modifiedAfter modified: TimeInterval? = nil
    ) -> KeroCodexThread {
        KeroCodexThread(
            id: id, rolloutPath: "/r/\(id).jsonl", cwd: cwd,
            createdAt: start.addingTimeInterval(seconds),
            modifiedAt: modified.map(start.addingTimeInterval), originator: "codex-tui"
        )!
    }

    private func makeCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a rollout shaped like Codex's: a `session_meta` header with the
    /// identifying fields ahead of the large base instructions, then a line
    /// per event.
    private func writeRollout(
        home: URL, day: String, id: String, cwd: String = "/repo",
        timestamp: String? = "2026-11-02T07:05:54.248Z", originator: String = "codex-tui",
        instructions: String = String(repeating: "i", count: 20 * 1024),
        trailing: String = #"{"type":"event_msg","payload":{}}"#
    ) throws -> URL {
        let directory = home.appendingPathComponent("sessions/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = day.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("rollout-\(stamp)T07-05-54-\(id).jsonl")
        let time = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        let header = #"{"timestamp":"2026-11-02T07:17:47.969Z","type":"session_meta","#
            + #""payload":{"session_id":"\#(id)","id":"\#(id)",\#(time)"cwd":"\#(cwd)","#
            + #""originator":"\#(originator)","source":"cli","#
            + #""base_instructions":{"text":"\#(instructions)"}}}"#
        try Data((header + "\n" + trailing + "\n").utf8).write(to: url)
        return url
    }
}
