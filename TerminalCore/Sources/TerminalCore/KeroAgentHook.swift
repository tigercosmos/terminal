//
//  KeroAgentHook.swift
//  TerminalCore
//

import Foundation

/// Turns one Claude Code or Codex hook event into what Terminal records
/// about the agent. Both run Terminal's bundled plugin hooks with the
/// event's JSON on stdin, in shapes close enough to share one reading; this
/// is the whole of it, kept free of the socket and the app so the mapping is
/// tested without either.
///
/// Every hook names its event on the command line rather than trusting
/// `hook_event_name` alone: the plugin file decides which events are wired,
/// and a field an agent renames must not silently re-route one.
public nonisolated enum KeroAgentHook {
    public enum Agent: String, Sendable {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }
    }

    public enum Action: Equatable, Sendable {
        /// The agent's own state: `working`, `blocked`, or `idle`.
        case report(state: String, reason: String)
        case subagentStarted(id: String, type: String)
        case subagentStopped(id: String)
        /// The main turn ended. Only background subagents can still be
        /// running; `ids` are the ones the agent still lists and `count`
        /// how many it lists, for the case where its task ids are not the
        /// ids `SubagentStart` reported.
        case subagentsRemaining(ids: [String], count: Int)
    }

    /// Background task types that will wake the main thread when they end,
    /// so a turn that stops while they run is still the agent at work. A
    /// background shell or monitor is not: a dev server can run for days, and
    /// an agent that left one running is done with its turn. Claude Code
    /// lists only running and pending tasks, so an idle teammate is absent.
    private static let awaitedBackgroundTypes: Set<String> = ["subagent", "teammate", "workflow"]

    /// The task types `SubagentStart` reports: agent team teammates run
    /// through the subagent hooks too, so both keep their roster rows.
    private static let agentBackgroundTypes: Set<String> = ["subagent", "teammate"]

    public static func actions(
        agent: Agent,
        event: String,
        input: KeroJSONValue?
    ) -> [Action] {
        let fields = input?.objectValue ?? [:]
        let name = agent.displayName
        switch event {
        case "UserPromptSubmit":
            return [.report(state: "working", reason: "\(name) prompt submitted")]

        // A tool finishing is the first event after a permission prompt is
        // answered; there is no event for the answer itself.
        case "PostToolUse", "PostToolUseFailure":
            return [.report(state: "working", reason: "\(name) ran a tool")]

        case "PermissionRequest":
            return [.report(state: "blocked", reason: "\(name) is waiting for permission")]

        // Claude Code only: Codex has no notification hook.
        case "Notification":
            switch fields["notification_type"]?.stringValue {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                return [.report(state: "blocked", reason: "\(name) is waiting for input")]
            // Stop does not run when the user interrupts a turn. This fires a
            // minute after Claude Code last answered with no new input, so an
            // interrupted turn does not read as working forever.
            case "idle_prompt":
                return [.report(state: "idle", reason: "\(name) is waiting for a prompt")]
            default:
                return []
            }

        // Codex only: it reports an interrupt, where Claude Code is silent.
        // An interrupt cancels the turn's subagents with it, and they report
        // no stop of their own, so the list is emptied before the idle.
        case "Interrupt":
            return [
                .subagentsRemaining(ids: [], count: 0),
                .report(state: "idle", reason: "\(name) turn interrupted"),
            ]

        case "Stop":
            // The turn did end, but an input that could not be read says
            // nothing about what still runs in the background. Leave the
            // subagent list as it is: the app keeps an agent with listed
            // subagents working, so an unreadable Stop cannot clear them and
            // call the agent done while they work. Codex's Stop never lists
            // background tasks, so its subagents leave only by their own stop.
            guard let tasks = fields["background_tasks"]?.arrayValue?.compactMap(\.objectValue) else {
                return [.report(state: "idle", reason: "\(name) finished its turn")]
            }
            let subagents = tasks.filter {
                agentBackgroundTypes.contains($0["type"]?.stringValue ?? "")
            }
            let remaining = Action.subagentsRemaining(
                ids: subagents.compactMap { $0["id"]?.stringValue },
                count: subagents.count
            )
            let awaited = tasks.contains {
                awaitedBackgroundTypes.contains($0["type"]?.stringValue ?? "")
            }
            return [
                remaining,
                awaited
                    ? .report(state: "working", reason: "\(name) is waiting for background agents")
                    : .report(state: "idle", reason: "\(name) finished its turn"),
            ]

        case "StopFailure":
            return [.report(state: "blocked", reason: "\(name) stopped on an error")]

        case "SubagentStart":
            // Claude Code also runs internal agents (prompt suggestions,
            // `/btw`) through the subagent hooks with an empty type. They are
            // not work the user asked for, so they get no row.
            guard let id = nonEmpty(fields["agent_id"]),
                  let type = nonEmpty(fields["agent_type"])
            else { return [] }
            return [
                .report(state: "working", reason: "\(name) started a subagent"),
                .subagentStarted(id: id, type: String(type.prefix(80))),
            ]

        case "SubagentStop":
            guard let id = nonEmpty(fields["agent_id"]) else { return [] }
            return [.subagentStopped(id: id)]

        default:
            return []
        }
    }

    /// The agent process a hook was run for, as the pids of its launcher
    /// chain: walking up from the hook, the first process recognized as an
    /// agent, then each parent while it is an agent of the same kind (an npm
    /// launcher above Codex's native binary). Empty when no agent is found.
    ///
    /// Every process in a pane inherits the pane's automation variables, so
    /// an agent run by the pane's agent — `claude -p` or `codex exec` from its
    /// shell tool — reports through the same socket. The app compares this
    /// chain with the pane's own agent and drops the inner agent's events.
    public static func reportingAgentPIDs(
        from pid: pid_t,
        recognize: (pid_t) -> KeroAgentKind? = { KeroAgentKind.recognize(processID: $0) },
        parent: (pid_t) -> pid_t? = { processParentPID(pid: $0) }
    ) -> [pid_t] {
        var current: pid_t? = pid
        var chain: [pid_t] = []
        var kind: KeroAgentKind?
        // Bounded: a hook is a few processes below its agent, and a loop in
        // stale kernel data must not spin.
        for _ in 0..<32 {
            guard let process = current else { break }
            if let recognized = recognize(process) {
                if let kind, recognized != kind { break }
                kind = recognized
                chain.append(process)
            } else if kind != nil {
                break
            }
            current = parent(process)
        }
        return chain
    }

    private static func nonEmpty(_ value: KeroJSONValue?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return string
    }
}

/// One subagent a pane's agent is running, in the order it started.
public nonisolated struct KeroAgentSubagent: Equatable, Sendable, Identifiable {
    public let id: String
    public let type: String

    public init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    /// Applies one change to a pane's subagent list. Kept beside the type so
    /// the reconciliation rules are tested without a session.
    public static func applying(
        _ action: KeroAgentHook.Action,
        to subagents: [Self]
    ) -> [Self] {
        switch action {
        case .subagentStarted(let id, let type):
            // A resumed subagent starts again under the same id.
            guard !subagents.contains(where: { $0.id == id }) else { return subagents }
            // Bounded: the ids come from a hook, and a runaway loop must not
            // grow a sidebar row without limit.
            return Array((subagents + [Self(id: id, type: type)]).suffix(32))
        case .subagentStopped(let id):
            return subagents.filter { $0.id != id }
        case .subagentsRemaining(let ids, let count):
            // A foreground subagent interrupted with Esc may never report its
            // stop; the end of the turn is when that is known. Keep the ones
            // still listed, else the most recent `count`, which are the ones
            // a turn that just ended can still be waiting on.
            // Claude Code's task ids are the agents' ids, so any match means
            // the ids can be trusted and nothing else is kept.
            let listed = subagents.filter { ids.contains($0.id) }
            if !listed.isEmpty || count == 0 { return listed }
            return Array(subagents.suffix(max(count, 0)))
        case .report:
            return subagents
        }
    }
}
