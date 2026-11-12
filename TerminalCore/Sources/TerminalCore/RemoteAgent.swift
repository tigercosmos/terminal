//
//  RemoteAgent.swift
//  TerminalCore
//

import Foundation

/// Remote process IDs never enter local process inspection or session restore.
/// The identity includes the host's process start time, so PID reuse starts a
/// new row even when it happens between two polls.
public nonisolated struct RemoteAgent: Equatable, Sendable {
    public let identity: String
    public let kind: KeroAgentKind
    public let processID: Int
    public let state: State?

    public struct State: Decodable, Equatable, Sendable {
        public let phase: String
        public let revision: Int64
        public let turn: Int64?
        public let subagents: [Subagent]
    }

    public struct Subagent: Decodable, Equatable, Sendable {
        public let id: String
        public let type: String
    }

    private struct Reply: Decodable {
        let version: Int
        let processes: [Record]
    }

    private struct Record: Decodable {
        let identity: String
        let pid: Int
        let parent: Int?
        let executable: String
        let arguments: [String]
        let state: State?

        private enum CodingKeys: String, CodingKey {
            case identity, pid, parent, executable, arguments, state
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            identity = try values.decode(String.self, forKey: .identity)
            pid = try values.decode(Int.self, forKey: .pid)
            parent = try values.decodeIfPresent(Int.self, forKey: .parent)
            executable = try values.decode(String.self, forKey: .executable)
            arguments = try values.decode([String].self, forKey: .arguments)
            // A torn or older hook file must not hide a process we recognized.
            state = try? values.decode(State.self, forKey: .state)
        }
    }

    /// First recognized process in foreground ancestry order wins. A node
    /// launcher and its native child are one agent, not two sidebar entries.
    public static func decode(_ data: Data) throws -> RemoteAgent? {
        guard data.count <= 128 * 1024 else { throw CocoaError(.coderReadCorrupt) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.version == 1, reply.processes.count <= 32 else {
            throw CocoaError(.coderReadCorrupt)
        }
        for initial in reply.processes {
            // npm's Codex launcher owns the foreground group while the native
            // direct child runs the hooks. Never borrow a nested tool agent's
            // report further down the tree.
            let record = initial.state == nil ? (reply.processes.first {
                $0.parent == initial.pid && $0.state != nil
                    && KeroAgentKind.recognize(executablePath: $0.executable, arguments: $0.arguments)
                        == KeroAgentKind.recognize(executablePath: initial.executable, arguments: initial.arguments)
            } ?? initial) : initial
            guard record.pid > 0, record.pid <= Int(Int32.max),
                  record.identity.utf8.count <= 100,
                  record.identity.range(of: "^[0-9]+-[a-f0-9]{24}$", options: .regularExpression) != nil,
                  let kind = KeroAgentKind.recognize(
                    executablePath: record.executable, arguments: record.arguments
                  )
            else { continue }
            var state = record.state
            if let value = state,
               !["working", "blocked", "idle"].contains(value.phase)
                || value.subagents.count > 64
                || value.subagents.contains(where: {
                    $0.id.utf8.count > 1024 || $0.type.utf8.count > 320
                        || $0.type.unicodeScalars.contains(where: {
                            [.control, .format, .lineSeparator, .paragraphSeparator]
                                .contains($0.properties.generalCategory)
                        })
                }) {
                state = nil
            }
            return RemoteAgent(identity: record.identity, kind: kind, processID: record.pid, state: state)
        }
        return nil
    }

    public static func helperSource() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "terminal_remote_agent", withExtension: "py", subdirectory: "RemoteAgents"
        ) else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func probe(
        connection: SSHConnection, timeout: TimeInterval = 30, on destination: RemoteShellDestination
    ) -> Result<RemoteAgent?, ProbeFailure> {
        do {
            let source = try helperSource()
            let arguments = [String(Int(connection.age) + 10)]
                + connection.ports.prefix(8).map { "\($0.client):\($0.server)" }
            let result = RemoteFileService.execute(
                script: probeScript,
                arguments: arguments, maxBytes: 128 * 1024,
                input: Data(source.utf8), timeout: timeout, on: destination
            )
            guard result.status == 0 else {
                return .failure(ProbeFailure(status: result.status))
            }
            return .success(try decode(result.stdout))
        } catch {
            return .failure(.unavailable)
        }
    }

    // Keep the login-shell command on one line, even for csh/tcsh. Python's
    // source travels on stdin, so it is neither shell syntax nor a ps argument.
    public static let probeScript = "exec python3 - probe \"$@\""
    public static let installScript = "umask 077; helper=$(mktemp) || exit 1; trap 'rm -f \"$helper\"' EXIT; cat > \"$helper\" || exit 1; python3 \"$helper\" install \"$1\""

    public enum ProbeFailure: Error, Sendable {
        case authentication
        case unsupported
        case unavailable

        public init(status: Int32) {
            switch status {
            case 255: self = .authentication
            case 127: self = .unsupported
            default: self = .unavailable
            }
        }
    }
}

/// Tracks completion acknowledgement separately from polling: the same idle
/// snapshot must not repeatedly notify, and a turn that starts and ends between
/// polls must still appear done when the pane was out of view.
public nonisolated struct RemoteAgentPresentation: Sendable {
    private var identity: String?
    private var seenTurn: Int64?
    private var unseenTurn: Int64?

    public init() {}

    public mutating func phase(for agent: RemoteAgent, isFocused: Bool) -> String {
        if identity != agent.identity {
            identity = agent.identity
            seenTurn = nil
            unseenTurn = nil
        }
        guard let state = agent.state else { return "unknown" }
        if isFocused, state.phase == "idle" {
            seenTurn = state.turn
            unseenTurn = nil
        } else if state.phase == "idle", let turn = state.turn, turn != seenTurn {
            unseenTurn = turn
        }
        return state.phase == "idle" && unseenTurn != nil ? "done" : state.phase
    }
}


/// One failed channel can be a panel closing its shared master. Preserve the
/// last answer once, then back off. Authentication and missing-Python failures
/// suspend discovery until a new SSH process or an explicit setting reset.
public nonisolated struct RemoteAgentPolling: Sendable {
    public private(set) var nextProbe = Date.distantPast
    public private(set) var failures = 0
    public private(set) var isSuspended = false
    private var hasSucceeded = false

    public init() {}

    public var timeout: TimeInterval { hasSucceeded ? 15 : 30 }
    public var isUnavailable: Bool { failures >= 2 || isSuspended }

    public func isDue(at now: Date) -> Bool { !isSuspended && now >= nextProbe }

    public mutating func succeeded(at now: Date) {
        failures = 0
        hasSucceeded = true
        nextProbe = now.addingTimeInterval(3)
    }

    public mutating func failed(_ reason: RemoteAgent.ProbeFailure, at now: Date) {
        failures += 1
        if reason == .unsupported || (reason == .authentication && (!hasSucceeded || failures >= 2)) {
            isSuspended = true
        }
        nextProbe = now.addingTimeInterval(min(60, 3 * pow(2, Double(min(failures, 5)))))
    }
}

/// The host controls event IDs. Deduplication alone therefore cannot prevent
/// a malicious hook file from posting a notification on every poll.
public nonisolated struct RemoteAgentNotifications: Sendable {
    private var lastEvent: String?
    private var lastNotification: Date?

    public init() {}

    public mutating func shouldNotify(event: String, at now: Date) -> Bool {
        guard event != lastEvent else { return false }
        lastEvent = event
        if let lastNotification, now.timeIntervalSince(lastNotification) < 30 { return false }
        lastNotification = now
        return true
    }
}
