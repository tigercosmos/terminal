//
//  KeroClaudeHookTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Claude Code's hooks are the only source of its working, blocked and done
/// states, and of its subagents. Each test feeds a hook's stdin as Claude
/// Code writes it and checks what Terminal records.
struct KeroClaudeHookTests {
    private func input(_ json: String) throws -> KeroJSONValue {
        try JSONDecoder().decode(KeroJSONValue.self, from: Data(json.utf8))
    }

    private func states(_ actions: [KeroClaudeHook.Action]) -> [String] {
        actions.compactMap {
            if case .report(let state, _) = $0 { return state }
            return nil
        }
    }

    @Test func aPromptStartsWorkAndAToolFinishingKeepsIt() {
        #expect(states(KeroClaudeHook.actions(event: "UserPromptSubmit", input: nil)) == ["working"])
        // The first event after a permission prompt is answered.
        #expect(states(KeroClaudeHook.actions(event: "PostToolUse", input: nil)) == ["working"])
        #expect(states(KeroClaudeHook.actions(event: "PostToolUseFailure", input: nil)) == ["working"])
    }

    @Test func waitingForTheUserIsBlocked() throws {
        #expect(states(KeroClaudeHook.actions(event: "PermissionRequest", input: nil)) == ["blocked"])
        #expect(states(KeroClaudeHook.actions(event: "StopFailure", input: nil)) == ["blocked"])
        let prompt = try input(#"{"notification_type": "permission_prompt"}"#)
        #expect(states(KeroClaudeHook.actions(event: "Notification", input: prompt)) == ["blocked"])
    }

    /// Stop does not run on an interrupt; the idle notice a minute later is
    /// what ends the turn then. Other notifications say nothing about state.
    @Test func onlyTheIdleNoticeAndPromptsAmongNotificationsChangeState() throws {
        let idle = try input(#"{"notification_type": "idle_prompt"}"#)
        #expect(states(KeroClaudeHook.actions(event: "Notification", input: idle)) == ["idle"])
        let auth = try input(#"{"notification_type": "auth_success"}"#)
        #expect(KeroClaudeHook.actions(event: "Notification", input: auth).isEmpty)
    }

    @Test func aStopWithNothingInTheBackgroundEndsTheTurn() throws {
        let stop = try input(#"{"stop_hook_active": false, "background_tasks": []}"#)
        #expect(KeroClaudeHook.actions(event: "Stop", input: stop) == [
            .subagentsRemaining(ids: [], count: 0),
            .report(state: "idle", reason: "Claude Code finished its turn"),
        ])
    }

    /// The main thread stops while background subagents run; they will wake
    /// it, so the agent is still at work. A background shell will not.
    @Test func aStopWaitingOnBackgroundAgentsIsStillWorking() throws {
        let waiting = try input(#"""
        {"background_tasks": [
          {"id": "a1", "type": "subagent", "status": "running", "description": "Find callers"},
          {"id": "b1", "type": "shell", "status": "running", "command": "npm run dev"}
        ]}
        """#)
        let actions = KeroClaudeHook.actions(event: "Stop", input: waiting)
        #expect(actions.first == .subagentsRemaining(ids: ["a1"], count: 1))
        #expect(states(actions) == ["working"])

        let server = try input(#"""
        {"background_tasks": [{"id": "b1", "type": "shell", "status": "running"}]}
        """#)
        #expect(states(KeroClaudeHook.actions(event: "Stop", input: server)) == ["idle"])
    }

    /// Agent team teammates run through the subagent hooks; one still at
    /// work keeps both its row and its lead working.
    @Test func aStopWaitingOnATeammateIsStillWorking() throws {
        let waiting = try input(#"""
        {"background_tasks": [{"id": "t1", "type": "teammate", "status": "running"}]}
        """#)
        let actions = KeroClaudeHook.actions(event: "Stop", input: waiting)
        #expect(actions.first == .subagentsRemaining(ids: ["t1"], count: 1))
        #expect(states(actions) == ["working"])
    }

    /// Input too large or cut short decodes to nothing. That must not read
    /// as "no background tasks" and clear the subagents still running.
    @Test func anUnreadableStopLeavesTheSubagentsAlone() {
        #expect(KeroClaudeHook.actions(event: "Stop", input: nil) == [
            .report(state: "idle", reason: "Claude Code finished its turn"),
        ])
    }

    @Test func subagentsAreReportedByIDAndType() throws {
        let start = try input(#"{"agent_id": "a1", "agent_type": "Explore"}"#)
        #expect(KeroClaudeHook.actions(event: "SubagentStart", input: start) == [
            .report(state: "working", reason: "Claude Code started a subagent"),
            .subagentStarted(id: "a1", type: "Explore"),
        ])
        let stop = try input(#"{"agent_id": "a1", "agent_type": "Explore"}"#)
        #expect(KeroClaudeHook.actions(event: "SubagentStop", input: stop) == [.subagentStopped(id: "a1")])
    }

    /// Prompt suggestions and `/btw` run as subagents with no type.
    @Test func internalAgentsGetNoRow() throws {
        let unnamed = try input(#"{"agent_id": "a9", "agent_type": ""}"#)
        #expect(KeroClaudeHook.actions(event: "SubagentStart", input: unnamed).isEmpty)
        #expect(KeroClaudeHook.actions(event: "SubagentStart", input: nil).isEmpty)
    }

    @Test func unknownEventsDoNothing() {
        #expect(KeroClaudeHook.actions(event: "PreCompact", input: nil).isEmpty)
    }

    // MARK: - Subagent list

    @Test func subagentsComeAndGoInStartOrder() {
        var list: [KeroAgentSubagent] = []
        list = KeroAgentSubagent.applying(.subagentStarted(id: "a", type: "Explore"), to: list)
        list = KeroAgentSubagent.applying(.subagentStarted(id: "b", type: "Plan"), to: list)
        // A resumed subagent starts again under its id.
        list = KeroAgentSubagent.applying(.subagentStarted(id: "a", type: "Explore"), to: list)
        #expect(list.map(\.id) == ["a", "b"])
        list = KeroAgentSubagent.applying(.subagentStopped(id: "a"), to: list)
        #expect(list.map(\.id) == ["b"])
    }

    /// An interrupted foreground subagent may never report its stop; the
    /// end of the turn drops it.
    @Test func theEndOfATurnDropsSubagentsNoLongerRunning() {
        let list = [
            KeroAgentSubagent(id: "a", type: "Explore"),
            KeroAgentSubagent(id: "b", type: "Plan"),
        ]
        #expect(KeroAgentSubagent.applying(.subagentsRemaining(ids: [], count: 0), to: list).isEmpty)
        #expect(KeroAgentSubagent.applying(.subagentsRemaining(ids: ["b"], count: 1), to: list)
            .map(\.id) == ["b"])
        // Task ids that do not match the hook's agent ids: keep the newest.
        #expect(KeroAgentSubagent.applying(.subagentsRemaining(ids: ["t7"], count: 1), to: list)
            .map(\.id) == ["b"])
    }

    @Test func theListIsBounded() {
        var list: [KeroAgentSubagent] = []
        for index in 0..<100 {
            list = KeroAgentSubagent.applying(.subagentStarted(id: "\(index)", type: "Explore"), to: list)
        }
        #expect(list.count == 32)
        #expect(list.last?.id == "99")
    }
}
