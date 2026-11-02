//
//  KeroAgentResumeTests.swift
//  TerminalCore
//

import Darwin
import Foundation
import Testing

@testable import TerminalCore

/// Resuming types a command into a fresh shell on the user's behalf. A wrong
/// id resumes someone else's conversation or none, and an id that is not a
/// plain UUID would put agent-written text on a command line, so every reader
/// here is strict about what it accepts.
struct KeroAgentResumeTests {
    private let id = "98f3d1f5-75fa-4557-9392-774c59005cbc"
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    // MARK: - Session ids

    @Test func aSessionIDIsAUUIDInEitherCase() {
        #expect(KeroAgentResume.isSessionID(id))
        #expect(KeroAgentResume.isSessionID(id.uppercased()))
        #expect(!KeroAgentResume.isSessionID("98f3d1f5-75fa-4557-9392-774c59005cb"))
        #expect(!KeroAgentResume.isSessionID("98f3d1f575fa455793927 74c59005cbc"))
        #expect(!KeroAgentResume.isSessionID("98f3d1f5-75fa-4557-9392-774c59005cbg"))
        #expect(!KeroAgentResume.isSessionID("98f3d1f5-75fa-4557-9392774c-59005cbc"))
        #expect(!KeroAgentResume.isSessionID(""))
        #expect(!KeroAgentResume.isSessionID("latest"))
    }

    @Test func aReferenceStoresALowercasedValidatedID() {
        let reference = KeroAgentSessionReference(kind: .claude, sessionID: id.uppercased())
        #expect(reference?.sessionID == id)
        #expect(KeroAgentSessionReference(kind: .claude, sessionID: "$(reboot)") == nil)
    }

    // MARK: - Claude Code

    @Test func theClaudeRegistryDefaultsToTheHomeConfig() {
        let url = KeroAgentResume.claudeRegistryURL(pid: 69559, homeURL: home, environment: [:])
        #expect(url.path == "/Users/me/.claude/sessions/69559.json")
        #expect(
            KeroAgentResume.claudeProjectsURL(homeURL: home, environment: [:]).path
                == "/Users/me/.claude/projects"
        )
    }

    @Test func theClaudeRegistryHonorsTheConfigOverride() {
        let environment = ["CLAUDE_CONFIG_DIR": "/opt/claude-config"]
        let url = KeroAgentResume.claudeRegistryURL(
            pid: 42, homeURL: home, environment: environment
        )
        #expect(url.path == "/opt/claude-config/sessions/42.json")
        #expect(
            KeroAgentResume.claudeProjectsURL(homeURL: home, environment: environment).path
                == "/opt/claude-config/projects"
        )
        // An empty override is how a shell unsets it in practice.
        let empty = KeroAgentResume.claudeRegistryURL(
            pid: 42, homeURL: home, environment: ["CLAUDE_CONFIG_DIR": ""]
        )
        #expect(empty.path == "/Users/me/.claude/sessions/42.json")
    }

    @Test func aMatchingRegistryNamesTheSession() {
        let reference = KeroAgentResume.claudeReference(
            registryJSON: registry(pid: 69559, sessionID: id), pid: 69559
        )
        #expect(reference?.kind == .claude)
        #expect(reference?.sessionID == id)
        #expect(reference?.transcriptPath == nil)
    }

    /// A crashed agent leaves its file behind, and a later process can reuse
    /// the pid; the file's own pid is what proves it belongs to this agent.
    @Test func aRegistryForAnotherPidIsIgnored() {
        #expect(KeroAgentResume.claudeReference(
            registryJSON: registry(pid: 69559, sessionID: id), pid: 70000
        ) == nil)
    }

    @Test func aBackgroundSessionIsNotResumed() {
        #expect(KeroAgentResume.claudeReference(
            registryJSON: registry(pid: 1, sessionID: id, kind: "bg"), pid: 1
        ) == nil)
    }

    @Test func aRegistryWithoutAUsableSessionIDIsIgnored() {
        #expect(KeroAgentResume.claudeReference(
            registryJSON: registry(pid: 1, sessionID: "'; rm -rf ~; '"), pid: 1
        ) == nil)
        #expect(KeroAgentResume.claudeReference(
            registryJSON: Data(#"{"pid":1,"cwd":"/x","kind":"interactive"}"#.utf8), pid: 1
        ) == nil)
        #expect(KeroAgentResume.claudeReference(registryJSON: Data("{".utf8), pid: 1) == nil)
    }

    // MARK: - Codex

    private var lock: String { "/Users/me/.codex/thread-writer-locks/\(id).lock" }
    private var rollout: String {
        "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T09-15-30-\(id).jsonl"
    }

    @Test func theLockAloneNamesTheThread() {
        let reference = KeroAgentResume.codexReference(openFilePaths: ["/dev/null", lock])
        #expect(reference?.kind == .codex)
        #expect(reference?.sessionID == id)
        #expect(reference?.transcriptPath == nil)
    }

    @Test func theRolloutAloneNamesTheThreadAndItsTranscript() {
        let reference = KeroAgentResume.codexReference(openFilePaths: [rollout])
        #expect(reference?.sessionID == id)
        #expect(reference?.transcriptPath == rollout)
    }

    /// The lock names the thread being written; a rollout open for another
    /// thread must not supply its id or its transcript.
    @Test func theLockWinsAndTakesItsOwnRollout() {
        let other = "/Users/me/.codex/sessions/2026/11/01/"
            + "rollout-2026-11-01T08-00-00-00000000-1111-2222-3333-444444444444.jsonl"
        let reference = KeroAgentResume.codexReference(openFilePaths: [other, rollout, lock])
        #expect(reference?.sessionID == id)
        #expect(reference?.transcriptPath == rollout)

        let withoutItsOwn = KeroAgentResume.codexReference(openFilePaths: [other, lock])
        #expect(withoutItsOwn?.sessionID == id)
        #expect(withoutItsOwn?.transcriptPath == nil)
    }

    @Test func aRelocatedCodexHomeStillMatches() {
        let reference = KeroAgentResume.codexReference(openFilePaths: [
            "/Volumes/work/codex-home/thread-writer-locks/\(id.uppercased()).lock"
        ])
        #expect(reference?.sessionID == id)
    }

    @Test func filesOutsideTheCodexLayoutAreIgnored() {
        #expect(KeroAgentResume.codexReference(openFilePaths: []) == nil)
        #expect(KeroAgentResume.codexReference(openFilePaths: [
            "/dev/ttys004",
            "/Users/me/.codex/log/codex-tui.log",
            "/Users/me/project/\(id).lock",
            "/Users/me/project/rollout-2026-11-02T09-15-30-\(id).jsonl",
            "/Users/me/.codex/thread-writer-locks/not-a-uuid.lock",
            "/Users/me/.codex/sessions/2026/11/02/rollout-\(id).jsonl",
            "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T09-15-30-\(id).json",
        ]) == nil)
    }

    // MARK: - Resuming

    @Test func eachAgentResumesWithItsOwnSyntax() throws {
        let claude = try #require(KeroAgentSessionReference(kind: .claude, sessionID: id))
        let codex = try #require(KeroAgentSessionReference(kind: .codex, sessionID: id))
        #expect(KeroAgentResume.resumeCommand(claude) == ["claude", "--resume", id])
        #expect(KeroAgentResume.resumeCommand(codex) == ["codex", "resume", id])
        #expect(KeroAgentResume.supportedKinds == [.claude, .codex])
    }

    @Test func theShellLineQuotesEveryWord() throws {
        let claude = try #require(KeroAgentSessionReference(kind: .claude, sessionID: id))
        let codex = try #require(KeroAgentSessionReference(kind: .codex, sessionID: id))
        #expect(KeroAgentResume.resumeShellLine(claude) == "'claude' '--resume' '\(id)'")
        #expect(KeroAgentResume.resumeShellLine(codex) == "'codex' 'resume' '\(id)'")
    }

    @Test func aDecodedReferenceIsValidatedToo() {
        let json = #"{"kind":"codex","sessionID":"x'; reboot; '"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(KeroAgentSessionReference.self, from: Data(json.utf8))
        }
    }

    // MARK: - Open files

    /// Codex is found through the files it holds open, so the reader has to
    /// see a file exactly while it is open and not after.
    @Test func anOpenFileIsListedOnlyWhileItIsOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-files-\(UUID().uuidString).jsonl")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try #require(realPath(url.path))

        let descriptor = open(url.path, O_RDONLY)
        try #require(descriptor >= 0)
        #expect(processOpenFilePaths(pid: getpid()).compactMap(realPath).contains(expected))

        close(descriptor)
        #expect(!processOpenFilePaths(pid: getpid()).compactMap(realPath).contains(expected))
    }

    @Test func noProcessHasNoOpenFiles() {
        #expect(processOpenFilePaths(pid: 0).isEmpty)
        #expect(processOpenFilePaths(pid: -1).isEmpty)
    }

    // MARK: - Helpers

    private func registry(pid: Int, sessionID: String, kind: String = "interactive") -> Data {
        Data(#"""
            {"pid":\#(pid),"sessionId":"\#(sessionID)","cwd":"/Users/me/terminal",
            "kind":"\#(kind)","entrypoint":"cli","status":"idle"}
            """#.utf8)
    }

    /// `/tmp` is a symlink to `/private/tmp`; the kernel reports the resolved
    /// path, so both sides are compared resolved.
    private func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
