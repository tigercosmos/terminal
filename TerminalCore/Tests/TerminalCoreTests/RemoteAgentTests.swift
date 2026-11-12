//
//  RemoteAgentTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

struct RemoteAgentTests {
    private func record(pid: Int = 42, start: String = "aaaaaaaaaaaaaaaaaaaaaaaa",
                        phase: String? = "idle", turn: Int64? = 100) -> [String: Any] {
        var result: [String: Any] = [
            "identity": "\(pid)-\(start)", "pid": pid, "executable": "/usr/bin/node",
            "arguments": ["node", "/opt/node_modules/@openai/codex/bin/codex.js"],
        ]
        if let phase {
            var state: [String: Any] = ["phase": phase, "revision": 101, "subagents": []]
            if let turn { state["turn"] = turn }
            result["state"] = state
        }
        return result
    }

    private func decode(_ records: [[String: Any]]) throws -> RemoteAgent? {
        try RemoteAgent.decode(JSONSerialization.data(withJSONObject: ["version": 1, "processes": records]))
    }

    @Test func launcherUsesItsNativeChildHooks() throws {
        let launcher = record(phase: nil)
        var native = record(pid: 43, phase: "blocked")
        native["parent"] = 42
        native["executable"] = "/opt/codex"
        native["arguments"] = ["codex"]
        let agent = try #require(try decode([launcher, native]))
        #expect(agent.kind == .codex)
        #expect(agent.processID == 43)
        #expect(agent.state?.phase == "blocked")
        native["parent"] = 99
        #expect(try decode([launcher, native])?.state == nil)
    }

    @Test func presenceDoesNotInventIdleAndNeverBecomesLocalEvidence() throws {
        let agent = try #require(try decode([record(phase: nil)]))
        var presentation = RemoteAgentPresentation()
        #expect(presentation.phase(for: agent, isFocused: false) == "unknown")
        #expect(try decode([]) == nil)
    }

    @Test func completionBetweenPollsAppearsOnceAndFocusAcknowledgesIt() throws {
        let idle = try #require(try decode([record()]))
        var presentation = RemoteAgentPresentation()
        #expect(presentation.phase(for: idle, isFocused: false) == "done")
        #expect(presentation.phase(for: idle, isFocused: false) == "done")
        #expect(presentation.phase(for: idle, isFocused: true) == "idle")
        #expect(presentation.phase(for: idle, isFocused: false) == "idle")
        let next = try #require(try decode([record(turn: 200)]))
        #expect(presentation.phase(for: next, isFocused: false) == "done")
    }

    @Test func watchingTheStartDoesNotAcknowledgeTheFinish() throws {
        var presentation = RemoteAgentPresentation()
        let working = try #require(try decode([record(phase: "working")]))
        #expect(presentation.phase(for: working, isFocused: true) == "working")
        let idle = try #require(try decode([record()]))
        #expect(presentation.phase(for: idle, isFocused: false) == "done")
    }

    @Test func startupIdleIsNotCompletionAndNewProcessDoesNotInheritAcknowledgement() throws {
        var presentation = RemoteAgentPresentation()
        let startup = try #require(try decode([record(turn: nil)]))
        #expect(presentation.phase(for: startup, isFocused: false) == "idle")
        let previous = try #require(try decode([record()]))
        #expect(presentation.phase(for: previous, isFocused: true) == "idle")
        let replacement = try #require(try decode([record(start: "bbbbbbbbbbbbbbbbbbbbbbbb")]))
        #expect(presentation.phase(for: replacement, isFocused: false) == "done")
    }

    @Test func hostileReportsCannotInjectStateOrUIControls() throws {
        var bad = record(phase: "finished-and-execute")
        #expect(try decode([bad])?.state == nil)
        bad = record()
        var state = try #require(bad["state"] as? [String: Any])
        state["subagents"] = [["id": "1", "type": "hidden\u{1b}[2J"]]
        bad["state"] = state
        #expect(try decode([bad])?.state == nil)
        bad["identity"] = "../../local-file"
        #expect(try decode([bad]) == nil)
        #expect(throws: (any Error).self) {
            try RemoteAgent.decode(Data(repeating: 32, count: 128 * 1024 + 1))
        }
    }

    @Test func remoteIntegrationReadinessIsSeparateFromActivity() throws {
        var item = record(phase: nil)
        item["integration"] = ["status": "ready", "restart": true]
        let agent = try #require(try decode([item]))
        #expect(agent.state == nil)
        #expect(agent.integration?.status == "ready")
        #expect(agent.integration?.restart == true)
        var presentation = RemoteAgentPresentation()
        #expect(presentation.phase(for: agent, isFocused: false) == "unknown")
        item["integration"] = ["status": 123, "restart": "invalid"]
        #expect(try decode([item])?.kind == .codex)
        #expect(try decode([item])?.integration == nil)
    }

    @Test func malformedHookStateKeepsProcessPresence() throws {
        for value: Any in ["not an object", ["phase": "idle"],
                           ["phase": "idle", "revision": "bad", "subagents": []]] {
            var item = record()
            item["state"] = value
            let agent = try #require(try decode([item]))
            #expect(agent.kind == .codex)
            #expect(agent.state == nil)
        }
    }

    @Test func failedChannelsBackOffAndOneTransientFailureKeepsTheLastAnswer() {
        let start = Date(timeIntervalSince1970: 1_000)
        var polling = RemoteAgentPolling()
        #expect(polling.timeout == 30)
        polling.succeeded(at: start)
        #expect(polling.timeout == 15)
        polling.failed(.unavailable, at: start)
        #expect(!polling.isUnavailable)
        #expect(!polling.isDue(at: start.addingTimeInterval(3)))
        #expect(polling.isDue(at: start.addingTimeInterval(6)))
        polling.failed(.unavailable, at: start.addingTimeInterval(6))
        #expect(polling.isUnavailable)
        #expect(!polling.isDue(at: start.addingTimeInterval(17)))
        #expect(polling.isDue(at: start.addingTimeInterval(18)))
        polling.succeeded(at: start.addingTimeInterval(18))
        #expect(!polling.isUnavailable)
        #expect(polling.isDue(at: start.addingTimeInterval(21)))
    }

    @Test func closingASharedMasterOnceDoesNotSuspendAnEstablishedPane() {
        var polling = RemoteAgentPolling()
        let start = Date(timeIntervalSince1970: 1_000)
        polling.succeeded(at: start)
        polling.failed(.authentication, at: start)
        #expect(!polling.isUnavailable)
        #expect(polling.isDue(at: start.addingTimeInterval(6)))
        polling.failed(.authentication, at: start.addingTimeInterval(6))
        #expect(polling.isUnavailable)
        #expect(!polling.isDue(at: .distantFuture))
    }

    @Test func authenticationAndMissingPythonStopFurtherLogins() {
        for status: Int32 in [255, 127] {
            var polling = RemoteAgentPolling()
            polling.failed(RemoteAgent.ProbeFailure(status: status), at: Date())
            #expect(polling.isUnavailable)
            #expect(!polling.isDue(at: Date.distantFuture))
            polling = RemoteAgentPolling()
            #expect(polling.isDue(at: Date()))
        }
    }

    @Test func notificationRateLimitSurvivesHostControlledEventChanges() {
        var notifications = RemoteAgentNotifications()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = notifications.shouldNotify(event: "first", at: start)
        #expect(first)
        for second in 1..<30 {
            let repeated = notifications.shouldNotify(event: "changed-\(second)", at: start.addingTimeInterval(Double(second)))
            #expect(!repeated)
        }
        let later = notifications.shouldNotify(event: "later", at: start.addingTimeInterval(30))
        let duplicate = notifications.shouldNotify(event: "later", at: start.addingTimeInterval(100))
        #expect(later)
        #expect(!duplicate)
    }

    @Test func bundledHelperCanProbeThisMachineWithoutInstallingAnything() throws {
        let source = try RemoteAgent.helperSource()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, value in value }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", source, "probe", "30", "1:1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try RemoteAgent.decode(data) == nil)
    }
}
