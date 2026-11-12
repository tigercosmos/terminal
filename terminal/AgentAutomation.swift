//
//  AgentAutomation.swift
//  terminal
//

import AppKit
import Foundation
import TerminalCore

enum KeroAgentPhase: String, Codable, CaseIterable, Sendable {
    case created
    case working
    case blocked
    case done
    case idle
    case unknown

    fileprivate var rollupPriority: Int {
        switch self {
        case .blocked: return 6
        case .done: return 5
        case .working: return 4
        case .unknown: return 3
        case .created: return 2
        case .idle: return 1
        }
    }

    /// Short agent state shown beside its name in the sidebar roster.
    /// `created` reads as "starting", the word the pane and tab badges already
    /// use for it: the raw case name says nothing to someone who never ran
    /// `terminal +agent start`.
    var rosterLabel: String {
        switch self {
        case .created: return String(localized: "starting", comment: "Agent state in the sidebar roster.")
        case .working: return String(localized: "working", comment: "Agent state in the sidebar roster.")
        case .blocked: return String(localized: "blocked", comment: "Agent state in the sidebar roster.")
        case .done: return String(localized: "done", comment: "Agent state in the sidebar roster.")
        case .idle: return String(localized: "idle", comment: "Agent state in the sidebar roster.")
        case .unknown: return String(localized: "unknown", comment: "Agent state in the sidebar roster.")
        }
    }
}

enum KeroAgentStateAuthority: String, Codable, Sendable {
    /// A native agent hook or plugin reported a complete lifecycle event.
    case integration
    /// Terminal recognized the foreground executable.
    case process
    /// Terminal just launched or prompted the agent and is awaiting a lifecycle event.
    case command
}

struct KeroAgentStatus: Equatable, Sendable {
    let alias: String
    let kind: KeroAgentKind
    let phase: KeroAgentPhase
    let authority: KeroAgentStateAuthority
    let reason: String
    let updatedAt: Date
    let processID: pid_t?
    /// Completion remains unseen until the pane itself receives focus. Reads
    /// through the automation API deliberately do not mutate this bit.
    let unseen: Bool
}

struct KeroAgentRollup: Equatable {
    let phase: KeroAgentPhase
    let count: Int
}

enum KeroAutomationReadError: Error {
    case agentNotIdle
}

/// Mutable evidence kept beside a `TerminalSession`. It is separate from the
/// published status so unchanged polling never invalidates AppKit/SwiftUI view
/// trees.
@MainActor
final class KeroAgentObservationState {
    var declaredKind: KeroAgentKind?
    var alias: String?
    var lastForegroundPID: pid_t?
    var integrationPhase: KeroAgentPhase?
    var integrationReason: String?
    /// Native integrations publish semantic idle, not whether that idle ended
    /// a turn. Track active-turn evidence so launching an already-idle CLI in
    /// the background never looks like a newly finished task.
    var integrationTurnActive = false
    var isCollectingAlternateScreenHistory = false
    /// A Terminal-launched process is `created` until its first guarded prompt.
    /// This lifecycle fact does not require guessing how the CLI renders UI.
    var awaitingInitialPrompt = false
    /// Shell input is asynchronous. Keep a freshly declared launch working
    /// briefly so the monitor cannot mistake the still-foreground shell for
    /// an agent that already exited before it has consumed the command.
    var commandGraceDeadline: Date?
    /// Monitor ticks since the agent's session reference was last read; see
    /// `refreshAgentSessionReference(kind:processID:)`. Reset when the
    /// foreground process changes, so a new agent is read on its first tick.
    var sessionReferenceTick = 0
    /// Whether the session reference has been seen live — among the agent's
    /// own files or Codex's live threads — rather than only seeded by a
    /// restore. Only a confirmed Codex reference is dropped when its thread
    /// is no longer live; a seeded one is kept until its resumed thread comes
    /// up or a thread this process has since used replaces it.
    var sessionReferenceConfirmed = false
    /// The idle an agent reported while its subagents ran, held back because
    /// they would wake it. Replayed once the last one stops, unless a new
    /// turn starts first.
    var deferredIdleReason: String?
    var remoteDestination: RemoteShellDestination?
    var remoteForegroundPID: pid_t?
    var remoteProbeID: UUID?
    var remotePolling = RemoteAgentPolling()
    var remoteAgent: RemoteAgent?
    var remoteLastIdentity: String?
    var remoteNotifications = RemoteAgentNotifications()
    var remotePresentation = RemoteAgentPresentation()
}

@MainActor
final class AgentAutomationMonitor {
    static let shared = AgentAutomationMonitor()

    /// Weak references in registration order, so panes refresh in the same
    /// order every tick; a weak hash table's order is arbitrary.
    private var sessions: [WeakSession] = []
    private var timer: Timer?
    /// Every live Codex thread on this machine, shared by all panes and read
    /// at most once per `codexThreadsLifetime`, only while some Codex pane
    /// asks: listing the locks and parsing each thread's rollout header is
    /// file I/O that would otherwise repeat once per Codex pane per tick.
    private var codexThreads: (threads: [KeroCodexThread], readAt: ContinuousClock.Instant)?
    private static let codexThreadsLifetime: Duration = .seconds(3)

    private struct WeakSession {
        weak var session: TerminalSession?
    }

    private init() {}

    func register(_ session: TerminalSession) {
        sessions.append(WeakSession(session: session))
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        sessions.removeAll { $0.session == nil }
        let liveSessions = sessions.compactMap(\.session).filter { !$0.hasExited }
        for session in liveSessions {
            session.refreshAutomationAgentState(
                isFocused: TerminalManager.automationIsSessionFocused(session.id)
            )
        }
        if liveSessions.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func liveCodexThreads() -> [KeroCodexThread] {
        let now = ContinuousClock.now
        if let codexThreads, now - codexThreads.readAt < Self.codexThreadsLifetime {
            return codexThreads.threads
        }
        let files = FileManager.default
        let home = KeroAgentResume.codexHomeURL(
            homeURL: files.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let threads = KeroAgentResume.codexLiveThreads(codexHome: home, fileManager: files)
        codexThreads = (threads, now)
        return threads
    }

    /// Whether another live pane runs a Codex agent in `cwd` that holds no
    /// session reference yet. Panes with a reference do not count: they no
    /// longer compete for a thread.
    func hasOtherUnreferencedCodexAgent(cwd: String, excluding session: TerminalSession) -> Bool {
        let directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return sessions.contains { entry in
            guard let other = entry.session, other !== session, !other.hasExited,
                  other.agentSessionReference == nil,
                  let status = other.agentStatus, status.kind == .codex,
                  let processID = status.processID,
                  let otherDirectory = processWorkingDirectory(pid: processID)
            else { return false }
            return URL(fileURLWithPath: otherDirectory).standardizedFileURL.path == directory
        }
    }

    /// Session ids every other live pane already holds, so one conversation is
    /// never attributed to two panes.
    func claimedAgentSessionIDs(excluding session: TerminalSession) -> Set<String> {
        Set(sessions.compactMap { entry -> String? in
            guard let other = entry.session, other !== session, !other.hasExited else { return nil }
            return other.agentSessionReference?.sessionID
        })
    }
}

/// Direct children of `pid`, at most 64, from libproc. Codex's npm launcher
/// is a node process running the native binary as its child, and Terminal
/// recognizes the launcher; the files naming a thread may be held by either.
nonisolated func processChildPIDs(pid: pid_t) -> [pid_t] {
    guard pid > 0 else { return [] }
    var children = [pid_t](repeating: 0, count: 64)
    // Returns a count of pids, not bytes, and never more than fit.
    let count = children.withUnsafeMutableBytes { buffer in
        proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return [] }
    return children.prefix(min(Int(count), children.count)).filter { $0 > 0 }
}

extension TerminalSession {
    var isShellAvailableForAutomation: Bool {
        guard !hasExited, let shellPid, shellPid > 0 else { return false }
        return surface.foregroundPid == shellPid
            && commandLifecycle.phase != .executing
    }

    /// A pane split a moment ago has no shell yet: its surface attaches on a
    /// later turn of the run loop, and the Ghostty surface only spawns its
    /// process then. Waits for that launch — and only that: a shell that is
    /// up but running a job is busy, and the caller says so at once.
    ///
    /// Bounded well inside the CLI's five-second socket timeout, so a pane
    /// that never starts still gets an answer rather than a dropped connection.
    func waitForAutomationShellLaunch() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !hasExited,
              shellPid == nil || surface.foregroundPid == nil,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func isAutomationAgentRunning(kind: KeroAgentKind) -> Bool {
        guard let foreground = surface.foregroundPid,
              foreground != shellPid else { return false }
        return KeroAgentKind.recognize(processID: foreground) == kind
    }

    /// Bounded viewport text for automation reads and diagnostics. Reading
    /// does not call `markAutomationAgentSeen()`.
    func automationVisibleText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        guard let text = surface.readVisibleText(
            maxLines: boundedLines, maxColumns: boundedColumns
        ) else { return "" }
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.prefix(boundedColumns)) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(boundedLines).joined(separator: "\n")
    }

    /// Recent host history for automation result reads. Unlike lifecycle
    /// detection, this deliberately asks the backend for bounded scrollback.
    func automationRecentText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        return TerminalHistorySerializer.previewText(
            from: surface,
            maxLines: boundedLines,
            maxColumns: boundedColumns
        ) ?? automationVisibleText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
    }

    /// Collects older transcript pages from an idle full-screen agent when its
    /// alternate buffer has no host scrollback. Every page overlaps the prior
    /// page, and the same wheel interface is driven back to the live bottom
    /// before the read completes. Unsupported applications simply return the
    /// passive recent snapshot after the first wheel event changes nothing.
    func automationReadText(
        maxLines: Int,
        maxColumns: Int,
        requireIdleAgentForHistory: Bool
    ) async throws -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        let recent = automationRecentText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
        let recentLines = Self.automationLines(recent)
        guard recentLines.count < boundedLines,
              !TerminalHistorySerializer.hasPrimaryScrollback(surface),
              terminalIsAtLiveBottom,
              let status = agentStatus,
              isAutomationAgentRunning(kind: status.kind),
              !agentObservation.isCollectingAlternateScreenHistory
        else { return recent }

        guard status.phase == .idle || status.phase == .done else {
            if requireIdleAgentForHistory { throw KeroAutomationReadError.agentNotIdle }
            return recent
        }

        var latestPage = Self.automationLines(
            automationVisibleText(
                maxLines: boundedLines,
                maxColumns: boundedColumns
            )
        )
        guard !latestPage.isEmpty else { return recent }

        var collected = latestPage
        let pageStep = min(max(latestPage.count - 4, 4), 50)
        var pagesMoved = 0
        agentObservation.isCollectingAlternateScreenHistory = true
        defer { agentObservation.isCollectingAlternateScreenHistory = false }

        while collected.count < boundedLines, pagesMoved < 32 {
            guard surface.sendApplicationScroll(lines: pageStep) else { break }
            pagesMoved += 1
            try? await Task.sleep(for: .milliseconds(90))

            let olderPage = Self.automationLines(
                automationVisibleText(
                    maxLines: boundedLines,
                    maxColumns: boundedColumns
                )
            )
            guard !olderPage.isEmpty, olderPage != latestPage else { break }
            let merged = Self.prependingAutomationPage(
                olderPage,
                previousPage: latestPage,
                collected: collected
            )
            guard merged != collected else { break }
            collected = merged
            latestPage = olderPage
        }

        if pagesMoved > 0 {
            // Each downward batch is at least as large as the upward page step;
            // two extra batches cover applications that clamp one wheel burst.
            for _ in 0..<(pagesMoved + 2) {
                guard surface.sendApplicationScroll(lines: -50) else { break }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        return collected.suffix(boundedLines).joined(separator: "\n")
    }

    private static func automationLines(_ text: String) -> [String] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func prependingAutomationPage(
        _ olderPage: [String],
        previousPage: [String],
        collected: [String]
    ) -> [String] {
        var olderContent = olderPage

        // Full-screen agents often pin an input/status footer while their
        // transcript scrolls. Drop one copy before looking for page overlap.
        let maximumFooter = min(8, min(olderPage.count, previousPage.count))
        var sharedFooter = 0
        if maximumFooter > 0 {
            for count in stride(from: maximumFooter, through: 1, by: -1)
            where Array(olderPage.suffix(count)) == Array(previousPage.suffix(count)) {
                sharedFooter = count
                break
            }
        }
        if sharedFooter > 0 { olderContent.removeLast(sharedFooter) }
        guard !olderContent.isEmpty else { return collected }

        let maximumOverlap = min(olderContent.count, collected.count)
        var overlap = 0
        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1)
            where Array(olderContent.suffix(count)) == Array(collected.prefix(count)) {
                overlap = count
                break
            }
        }
        return Array(olderContent.dropLast(overlap)) + collected
    }

    /// `grace` is how long the shell may take to turn the typed command into
    /// the agent process before the declaration lapses. The default covers a
    /// shell sitting at its prompt; a restore types into shells that are still
    /// sourcing their rc files, a dozen at once, and needs longer.
    func declareAutomationAgent(alias: String, kind: KeroAgentKind, grace: TimeInterval = 5) {
        // A declaration is a fresh launch. The previous agent's status may
        // not have been cleared yet if the monitor has not ticked since it
        // exited, so drop its roster label and conversation here rather than
        // carry them over to this one.
        agentCustomLabel = nil
        agentSessionReference = nil
        agentSubagents = []
        agentObservation.sessionReferenceConfirmed = false
        agentObservation.alias = alias
        agentObservation.declaredKind = kind
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = false
        agentObservation.deferredIdleReason = nil
        agentObservation.awaitingInitialPrompt = true
        agentObservation.commandGraceDeadline = Date().addingTimeInterval(grace)
        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: .working,
            authority: .command,
            reason: "Terminal launched \(kind.displayName)",
            processID: nil,
            unseen: false
        )
    }

    func markAutomationAgentPrompted() {
        guard let status = agentStatus else { return }
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = true
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        updateAutomationAgentStatus(
            alias: status.alias,
            kind: status.kind,
            phase: .working,
            authority: .command,
            reason: "Prompt submitted",
            processID: surface.foregroundPid,
            unseen: false
        )
    }

    /// `reporter` is the hook's agent process chain, when the hook sent one;
    /// see `isFromPaneAgent(_:)`.
    func reportAutomationAgent(
        phase reportedPhase: KeroAgentPhase,
        reason reportedReason: String?,
        reporter: [pid_t]? = nil
    ) -> Bool {
        guard isFromPaneAgent(reporter) else { return false }
        // A main thread whose turn ended while its background subagents run
        // has not finished: they will wake it with their results. Presenting
        // it idle, or posting "finished", would send the user to a pane with
        // nothing to answer yet.
        let waitsOnSubagents = (reportedPhase == .idle || reportedPhase == .done)
            && !agentSubagents.isEmpty
        let phase: KeroAgentPhase = waitsOnSubagents ? .working : reportedPhase
        let reason = waitsOnSubagents
            ? "Waiting for subagents (\(agentSubagents.count))"
            : reportedReason
        agentObservation.deferredIdleReason = waitsOnSubagents
            ? (reportedReason ?? "Reported by native agent integration")
            : nil
        let foreground = surface.foregroundPid
        let rememberedProcess = agentStatus?.processID
        let recognized = [rememberedProcess, foreground]
            .compactMap { $0 }
            .lazy
            .compactMap { processID -> (pid_t, KeroAgentKind)? in
                KeroAgentKind.recognize(processID: processID).map { (processID, $0) }
            }
            .first
        guard let (processID, detected) = recognized else { return false }
        let kind = agentStatus?.kind ?? agentObservation.declaredKind ?? detected
        guard kind == detected else { return false }
        let alias = agentStatus?.alias ?? agentObservation.alias ?? kind.rawValue
        agentObservation.alias = alias
        agentObservation.declaredKind = kind
        let focused = TerminalManager.automationIsSessionFocused(id)
        agentObservation.integrationPhase = phase
        agentObservation.integrationReason = reason
        agentObservation.commandGraceDeadline = nil
        if phase == .working || phase == .blocked {
            agentObservation.integrationTurnActive = true
            // A turn is under way, so a task was submitted, whether through
            // `terminal +agent prompt` or typed into the pane. Without this,
            // a typed prompt's end would read as "starting" again.
            agentObservation.awaitingInitialPrompt = false
        }

        // A newly launched interactive CLI commonly publishes its initial idle
        // event before Terminal submits any task. Keep the deliberate `created`
        // state; readiness is process recognition, not a disposable lifecycle
        // turn that should appear as background completion.
        if agentObservation.awaitingInitialPrompt, phase == .idle {
            agentObservation.integrationPhase = nil
            agentObservation.integrationReason = nil
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .created,
                authority: .process,
                reason: "Agent process created; no task has been submitted",
                processID: processID,
                unseen: false
            )
            return true
        }

        // An unseen completion stays one through later idle events (Claude
        // Code's minute-later idle notice among them): only focusing the
        // pane acknowledges it.
        let completedTurn = agentObservation.integrationTurnActive
            || agentStatus?.phase == .working
            || agentStatus?.phase == .blocked
            || (agentStatus?.phase == .done && agentStatus?.unseen == true)
        let presentedPhase: KeroAgentPhase
        switch phase {
        case .idle, .done:
            presentedPhase = completedTurn && !focused ? .done : .idle
            agentObservation.integrationTurnActive = false
        default:
            presentedPhase = phase
        }
        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: presentedPhase,
            authority: .integration,
            reason: reason ?? "Reported by native agent integration",
            processID: processID,
            unseen: presentedPhase == .done
        )
        return true
    }

    /// Applies a subagent change from the agent's native integration.
    /// Refused, like a state report, unless a recognized agent runs here: a
    /// stray hook must not give a plain shell a roster row.
    func reportAutomationSubagents(
        _ change: KeroAgentHook.Action,
        reporter: [pid_t]? = nil
    ) -> Bool {
        // The same recognition `reportAutomationAgent` uses, remembered
        // process first, so a Stop hook's subagent change and its state
        // report are accepted or refused together.
        guard isFromPaneAgent(reporter),
              let status = agentStatus,
              [status.processID, surface.foregroundPid].compactMap({ $0 })
                  .contains(where: { KeroAgentKind.recognize(processID: $0) == status.kind })
        else { return false }
        let updated = KeroAgentSubagent.applying(change, to: agentSubagents)
        if updated != agentSubagents { agentSubagents = updated }
        if updated.isEmpty { replayDeferredIdle() }
        return true
    }

    /// Whether a hook's report is about this pane's agent. Every process in
    /// the pane inherits its automation variables, so an agent the pane's
    /// agent runs — `codex exec` or `claude -p` from its shell tool — reports
    /// here too, and its Stop would end the outer agent's turn. A hook that
    /// sends no chain (OpenCode, Pi, Grok Build) is taken as before.
    private func isFromPaneAgent(_ reporter: [pid_t]?) -> Bool {
        guard let reporter else { return true }
        let own = [agentStatus?.processID, surface.foregroundPid].compactMap { $0 }
        return reporter.contains { own.contains($0) }
    }

    /// The last subagent stopped after its agent's turn had ended. When it
    /// was a background subagent the agent usually wakes for its result at
    /// once, so the held-back idle waits a moment: replayed straight away it
    /// would flash "done" and post a notification between the two.
    private func replayDeferredIdle() {
        guard let reason = agentObservation.deferredIdleReason else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self, self.agentSubagents.isEmpty,
                  self.agentObservation.deferredIdleReason == reason
            else { return }
            _ = self.reportAutomationAgent(phase: .idle, reason: reason)
        }
    }

    func markAutomationAgentSeen() {
        guard let status = agentStatus, status.phase == .done || status.unseen else { return }
        if let destination = agentObservation.remoteDestination,
           let agent = agentObservation.remoteAgent {
            presentRemoteAgent(agent, on: destination, isFocused: true)
            return
        }
        guard isAutomationAgentRunning(kind: status.kind) else {
            clearAutomationAgentStatus()
            return
        }
        agentObservation.integrationPhase = .idle
        agentObservation.integrationReason = "Completion viewed"
        agentObservation.integrationTurnActive = false
        updateAutomationAgentStatus(
            alias: status.alias,
            kind: status.kind,
            phase: .idle,
            authority: status.authority,
            reason: "Completion viewed",
            processID: status.processID,
            unseen: false
        )
    }

    fileprivate func refreshAutomationAgentState(isFocused: Bool) {
        if isFocused { markAutomationAgentSeen() }

        if let destination = remoteDestination, let foreground = surface.foregroundPid,
           AppSettings.shared.remoteAgentDiscovery {
            refreshRemoteAgent(on: destination, foreground: foreground, isFocused: isFocused)
            return
        }
        if agentObservation.remoteDestination != nil {
            agentObservation.remoteDestination = nil
            agentObservation.remoteProbeID = nil
            agentObservation.remoteAgent = nil
            clearAutomationAgentStatus()
        }

        let foreground = surface.foregroundPid
        let shell = shellPid
        let processIsAgent = foreground != nil && foreground != shell
        let detectedKind = processIsAgent
            ? foreground.flatMap(KeroAgentKind.recognize(processID:))
            : nil
        let kind = detectedKind
        if detectedKind != nil {
            agentObservation.commandGraceDeadline = nil
        }

        if foreground != agentObservation.lastForegroundPID {
            agentObservation.lastForegroundPID = foreground
            agentObservation.sessionReferenceTick = 0
            // A different agent process in the same pane between two ticks
            // is a relaunch the status never cleared for. The roster label
            // and the conversation belonged to the old one, so neither may
            // carry over.
            if processIsAgent, let previous = agentStatus?.processID,
               let foreground, previous != foreground {
                agentCustomLabel = nil
                agentSessionReference = nil
                agentSubagents = []
                agentObservation.sessionReferenceConfirmed = false
            }
            if !processIsAgent {
                agentObservation.integrationPhase = nil
                agentObservation.integrationReason = nil
            }
        }

        guard let kind else {
            guard let previous = agentStatus else { return }
            if !processIsAgent {
                if previous.phase == .working,
                   previous.authority == .command,
                   let deadline = agentObservation.commandGraceDeadline,
                   Date() < deadline {
                    return
                }
                clearAutomationAgentStatus()
            }
            return
        }

        if let foreground {
            refreshAgentSessionReference(kind: kind, processID: foreground)
        }

        let alias = agentObservation.alias ?? agentStatus?.alias ?? kind.rawValue
        agentObservation.alias = alias
        let declaredKind = agentObservation.declaredKind
        agentObservation.declaredKind = kind

        // Directly launched CLIs have no `agent.start` declaration. Process
        // recognition records an idle presence, but terminal text never changes
        // lifecycle state; only commands and native integrations do that.
        if agentStatus == nil,
           agentObservation.integrationPhase == nil {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .idle,
                authority: .process,
                reason: "Directly launched \(kind.displayName) detected",
                processID: foreground,
                unseen: false
            )
        }

        if let phase = agentObservation.integrationPhase,
           phase != .working, phase != .blocked {
            // Presentation is decided when the native event arrives. Preserve
            // it until a new event or explicit focus acknowledges completion;
            // otherwise leaving an idle pane would turn it back into `done`.
            let currentPresentation = agentStatus.flatMap { status in
                status.authority == .integration
                    && (status.phase == .idle || status.phase == .done)
                    ? status : nil
            }
            let normalized = currentPresentation?.phase
                ?? ((phase == .idle || phase == .done) ? .idle : phase)
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: normalized,
                authority: .integration,
                reason: agentObservation.integrationReason
                    ?? "Reported by native agent integration",
                processID: foreground,
                unseen: currentPresentation?.unseen ?? (normalized == .done)
            )
            return
        }

        if agentObservation.awaitingInitialPrompt, declaredKind == kind {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .created,
                authority: .process,
                reason: "Agent process created; no task has been submitted",
                processID: foreground,
                unseen: false
            )
            return
        }

        if let phase = agentObservation.integrationPhase {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: phase,
                authority: .integration,
                reason: agentObservation.integrationReason
                    ?? "Reported by native agent integration",
                processID: foreground,
                unseen: false
            )
            return
        }

        if let current = agentStatus,
           current.phase == .working,
           current.authority == .command {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .working,
                authority: .command,
                reason: current.reason,
                processID: foreground,
                unseen: false
            )
            return
        }

        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: .idle,
            authority: .process,
            reason: "Directly launched \(kind.displayName) detected",
            processID: foreground,
            unseen: false
        )
    }

    /// Keeps `agentSessionReference` naming the conversation the agent here
    /// is in. Re-read every fourth tick (about 3 s) even once found, because
    /// `/clear` in Claude Code and `/new` in Codex start a new session in the
    /// same process, and the pane should resume the one on screen. A file read,
    /// a few descriptor listings, and two process lookups per agent at that
    /// rate are cheap; the machine-wide Codex thread list is shared through
    /// the monitor; and panes without a recognized agent never get here.
    private func refreshAgentSessionReference(kind: KeroAgentKind, processID: pid_t) {
        guard KeroAgentResume.supportedKinds.contains(kind) else { return }
        let tick = agentObservation.sessionReferenceTick
        agentObservation.sessionReferenceTick += 1
        guard tick % 4 == 0 else { return }

        switch kind {
        case .claude:
            let registry = KeroAgentResume.claudeRegistryURL(
                pid: processID,
                homeURL: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
            // Missing until Claude Code registers its session, and in versions
            // without a registry; either way there is nothing to record yet.
            // A read that finds nothing keeps the last answer: the file can
            // be mid-rewrite, and the conversation last seen is still the
            // best one to resume. Read only as a bounded regular file: the
            // directory is writable by anything running as the user, and a
            // FIFO or device planted there would block the main thread.
            if let found = readRegularFilePrefix(at: registry, maxBytes: 64 * 1024).flatMap({
                KeroAgentResume.claudeReference(registryJSON: $0, pid: processID)
            }) {
                adoptAgentSessionReference(found)
            }
        case .codex:
            refreshCodexSessionReference(processID: processID)
        default:
            return
        }
    }

    private func refreshCodexSessionReference(processID: pid_t) {
        // `codex exec` and older TUIs hold their thread's lock and rollout
        // themselves, in the recognized process or the native binary under
        // its node launcher. That names the thread exactly, so it wins.
        let candidates = [processID] + processChildPIDs(pid: processID)
        if let found = candidates.lazy.compactMap({
            KeroAgentResume.codexReference(openFilePaths: processOpenFilePaths(pid: $0))
        }).first {
            adoptAgentSessionReference(found)
            return
        }

        // Current TUIs leave both files to a shared `codex app-server` that
        // holds every live thread's, so the thread is matched to this pane by
        // the agent's directory and start time instead.
        let monitor = AgentAutomationMonitor.shared
        let threads = monitor.liveCodexThreads()
        if let current = agentSessionReference {
            // A live reference is kept as is. Matching goes by when threads
            // were used, so re-running it could move the pane onto another
            // thread in the same directory that happened to be used later.
            if threads.contains(where: { $0.id == current.sessionID }) {
                agentObservation.sessionReferenceConfirmed = true
                return
            }
            if agentObservation.sessionReferenceConfirmed {
                // The thread ended or `/new` replaced it; match whatever runs now.
                agentSessionReference = nil
                agentObservation.sessionReferenceConfirmed = false
            }
            // A reference seeded by a restore is kept while its resumed thread
            // is not live yet: dropped, a quit before the next prompt would
            // save the pane without its conversation. Matching still runs: it only finds a thread this process
            // has used since it started, so a match means the user moved on
            // from the seeded conversation.
        }
        // The agent's own directory and start, not the shell's: the thread
        // records where Codex ran, and only threads used since it started
        // can be its own.
        guard let cwd = processWorkingDirectory(pid: processID),
              let startedAt = processStartDate(pid: processID)
        else { return }
        // Two unmatched Codex agents in one directory cannot be told apart:
        // nothing Terminal sees says which pane prompted first, and a guess
        // can hand each pane the other's conversation. Wait instead; once one
        // exits its thread lock goes with it and the survivor's thread is the
        // only candidate left.
        guard !monitor.hasOtherUnreferencedCodexAgent(cwd: cwd, excluding: self),
              let thread = KeroAgentResume.attributeCodexThread(
                  // Threads other front ends start in the same directory — a
                  // Codex run driven by a Claude Code plugin reports its own
                  // originator — are not this pane's conversation.
                  threads: threads.filter { $0.originator == nil || $0.originator == "codex-tui" },
                  cwd: cwd, startedAt: startedAt,
                  claimed: monitor.claimedAgentSessionIDs(excluding: self)
              )
        else { return }
        agentSessionReference = KeroAgentResume.reference(for: thread)
        agentObservation.sessionReferenceConfirmed = true
    }

    private func adoptAgentSessionReference(_ found: KeroAgentSessionReference) {
        agentObservation.sessionReferenceConfirmed = true
        guard found != agentSessionReference else { return }
        // A Codex lock seen without its rollout names the same conversation
        // with nothing for a restore to check; keep the fuller reference.
        if let current = agentSessionReference,
           current.sessionID == found.sessionID,
           current.transcriptPath != nil, found.transcriptPath == nil {
            return
        }
        agentSessionReference = found
    }

    private func clearAutomationAgentStatus() {
        agentStatus = nil
        agentRemoteHost = nil
        agentRemoteIntegration = nil
        agentCustomLabel = nil
        agentSessionReference = nil
        agentSubagents = []
        agentObservation.sessionReferenceConfirmed = false
        agentObservation.alias = nil
        agentObservation.declaredKind = nil
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = false
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        agentObservation.deferredIdleReason = nil
    }

    private func updateAutomationAgentStatus(
        alias: String,
        kind: KeroAgentKind,
        phase: KeroAgentPhase,
        authority: KeroAgentStateAuthority,
        reason: String,
        processID: pid_t?,
        unseen: Bool,
        notify: Bool = true
    ) {
        if let current = agentStatus,
           current.alias == alias,
           current.kind == kind,
           current.phase == phase,
           current.authority == authority,
           current.reason == reason,
           current.processID == processID,
           current.unseen == unseen {
            return
        }

        let previousPhase = agentStatus?.phase
        agentStatus = KeroAgentStatus(
            alias: alias,
            kind: kind,
            phase: phase,
            authority: authority,
            reason: reason,
            updatedAt: Date(),
            processID: processID,
            unseen: unseen
        )

        guard notify, phase != previousPhase,
              phase == .blocked || phase == .done,
              !TerminalManager.automationIsSessionFocused(id)
        else { return }
        TerminalNotificationService.shared.post(
            message: phase == .blocked
                ? String(localized: "\(alias) needs attention")
                : String(localized: "\(alias) finished"),
            sessionID: id
        )
    }
}

extension PaneTab {
    var agentRollup: KeroAgentRollup? {
        Self.rollup(sessions.compactMap(\.agentStatus))
    }

    fileprivate static func rollup(_ statuses: [KeroAgentStatus]) -> KeroAgentRollup? {
        // Idle and unknown remain useful to automation clients, but neither is
        // actionable enough to occupy persistent pane, tab, or project chrome.
        let visibleStatuses = statuses.filter {
            $0.phase != .idle && $0.phase != .unknown
        }
        guard let phase = visibleStatuses.map(\.phase).max(by: {
            $0.rollupPriority < $1.rollupPriority
        }) else { return nil }
        return KeroAgentRollup(
            phase: phase,
            count: visibleStatuses.filter { $0.phase == phase }.count
        )
    }
}

extension TerminalSession {
    var agentRollup: KeroAgentRollup? {
        PaneTab.rollup(agentStatus.map { [$0] } ?? [])
    }

    /// Installation readiness is separate from actual agent activity. Native
    /// hook approval and restarting an existing CLI remain provider actions.
    var agentRosterLabel: String {
        if agentStatus?.phase == .unknown, let integration = agentRemoteIntegration {
            switch integration.status {
            case "installing": return String(localized: "setting up")
            case "failed": return String(localized: "setup failed")
            case "ready":
                return integration.restart
                    ? String(localized: "restart agent")
                    : String(localized: "waiting for hooks")
            default: break
            }
        }
        return agentStatus?.phase.rosterLabel ?? ""
    }

    var agentIntegrationHelp: String {
        guard let integration = agentRemoteIntegration else { return "" }
        switch integration.status {
        case "ready":
            return String(localized: "Remote hooks are installed. Restart the remote agent if needed and approve its hooks when asked.")
        case "failed":
            return String(localized: "Remote hook setup failed. Terminal will retry automatically.")
        default: return ""
        }
    }

    /// The name the sidebar roster shows for this pane's agent. Meaningful
    /// only while `agentStatus` is set; without one it falls back to the
    /// label or an empty kind name.
    var agentDisplayName: String {
        let name = KeroAgentRoster.displayName(
            customLabel: agentCustomLabel,
            alias: agentStatus?.alias,
            kindName: agentStatus?.kind.displayName ?? ""
        )
        return agentRemoteHost.map { "\(name) · \($0)" } ?? name
    }

    /// What a saved pane needs to bring this agent's conversation back on
    /// relaunch; nil unless a resumable agent is running here.
    var agentResumeSnapshot: SessionSnapshot.ProjectSnapshot.AgentSnapshot? {
        guard let status = agentStatus, let reference = agentSessionReference else { return nil }
        return SessionSnapshot.ProjectSnapshot.AgentSnapshot(
            reference: reference, alias: status.alias, customLabel: agentCustomLabel
        )
    }

    /// Session ids already resumed in the current restore pass. Static because
    /// one pass spans every window restored from the same saved state, and
    /// the panes holding a conversation twice may sit in different windows.
    private static var resumedAgentSessionIDs: Set<String> = []
    /// Resumes scheduled so far in the current pass, which sets each one's
    /// start delay.
    private static var scheduledAgentResumeCount = 0

    /// Starts a new restore pass, forgetting which conversations the last one
    /// resumed. A process starts with a fresh pass; this is for saved state
    /// re-queued while the app keeps running.
    static func beginAgentResumePass() {
        resumedAgentSessionIDs = []
        scheduledAgentResumeCount = 0
    }

    /// Brings back the agent conversation a restored pane held, by typing the
    /// agent's own resume command into this freshly launched shell once it is
    /// ready. Any check that fails leaves the pane a plain shell.
    func resumeAgentAfterRestore(_ snapshot: SessionSnapshot.ProjectSnapshot.AgentSnapshot) {
        // The setting gates only this step. The reference was saved either
        // way, so turning the setting on later still has one to resume.
        guard AppSettings.shared.resumeAgentsOnRestore else { return }
        // The task below captures only these Sendable parts of the snapshot.
        let (reference, alias, customLabel) = (
            snapshot.reference, snapshot.alias, snapshot.customLabel
        )
        // A conversation whose transcript is gone, or that never got as far
        // as writing one, would leave the agent printing an error where the
        // user expected their conversation.
        guard Self.agentTranscriptExists(reference) else { return }
        // Two panes resuming one conversation would both append to the same
        // transcript and drift apart; the first pane restored keeps it.
        guard Self.resumedAgentSessionIDs.insert(reference.sessionID).inserted else { return }
        // Staggered so a workspace full of agents does not start them all in
        // the same instant, each loading its whole transcript at once.
        let delay = 150 * Self.scheduledAgentResumeCount
        Self.scheduledAgentResumeCount += 1

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self else { return }
            await waitForAutomationShellLaunch()
            // Typed into a shell that never came up, or into a job already
            // running, the command would reach the wrong program — the same
            // rule `terminal +agent start` follows.
            guard isShellAvailableForAutomation, agentStatus == nil else { return }
            // Every restored shell starts at once, so the one this command
            // lands in may take well over the usual grace to reach the agent;
            // lapsing early would re-detect it as hand-launched and lose the
            // alias and the conversation reference seeded below.
            declareAutomationAgent(alias: alias, kind: reference.kind, grace: 60)
            agentCustomLabel = customLabel
            // Seeded so a save before the monitor first reads the agent's own
            // files still carries the conversation; that read replaces it.
            agentSessionReference = reference
            sendCommand(KeroAgentResume.resumeShellLine(reference) + "\r")
        }
    }

    private static func agentTranscriptExists(_ reference: KeroAgentSessionReference) -> Bool {
        let files = FileManager.default
        switch reference.kind {
        case .claude:
            let projects = KeroAgentResume.claudeProjectsURL(
                homeURL: files.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            )
            // Claude Code files each transcript under a directory named for
            // where the session started. Looking one level down for the id
            // avoids reproducing that naming, which the agent owns.
            let name = reference.sessionID + ".jsonl"
            let directories = (try? files.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil
            )) ?? []
            return directories.contains {
                files.fileExists(atPath: $0.appendingPathComponent(name).path)
            }
        case .codex:
            // The rollout path comes from the files Codex held open. Without
            // one there is no telling the conversation was ever written.
            guard let path = reference.transcriptPath else { return false }
            return files.fileExists(atPath: path)
        default:
            return false
        }
    }
}

extension Project {
    var agentRollup: KeroAgentRollup? {
        PaneTab.rollup(sessions.compactMap(\.agentStatus))
    }
}

extension TerminalSession {
    /// One bounded enquiry per SSH pane, off the main actor. Destination and
    /// foreground PID guard the reply: a slow answer from a departed host must
    /// never create an agent in the local shell the user returned to.
    private func refreshRemoteAgent(
        on destination: RemoteShellDestination, foreground: pid_t, isFocused: Bool
    ) {
        let observation = agentObservation
        if observation.remoteDestination != destination || observation.remoteForegroundPID != foreground {
            clearAutomationAgentStatus()
            observation.remoteDestination = destination
            observation.remoteForegroundPID = foreground
            observation.remoteProbeID = nil
            observation.remotePolling = RemoteAgentPolling()
            observation.remoteAgent = nil
            observation.remoteLastIdentity = nil
            observation.remoteNotifications = RemoteAgentNotifications()
            observation.remotePresentation = RemoteAgentPresentation()
        }
        if let agent = observation.remoteAgent {
            presentRemoteAgent(agent, on: destination, isFocused: isFocused)
        }
        guard observation.remoteProbeID == nil, observation.remotePolling.isDue(at: Date()) else { return }
        guard let connection = sshConnection(pid: foreground) else {
            // A multiplexed client may have no TCP socket of its own. Without
            // enough evidence to identify its channel, never borrow another's.
            observation.remotePolling.failed(.unsupported, at: Date())
            observation.remoteAgent = nil
            markRemoteAgentUnavailable()
            return
        }
        let timeout = observation.remotePolling.timeout
        let probeID = UUID()
        observation.remoteProbeID = probeID
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                RemoteAgent.probe(connection: connection, timeout: timeout, on: destination)
            }.value
            guard let self, !self.hasExited,
                  self.agentObservation.remoteProbeID == probeID else { return }
            self.agentObservation.remoteProbeID = nil
            guard self.surface.foregroundPid == foreground,
                  self.remoteDestination == destination else { return }
            switch result {
            case .success(let agent):
                self.agentObservation.remotePolling.succeeded(at: Date())
                if self.agentObservation.remoteLastIdentity != agent?.identity {
                    self.clearAutomationAgentStatus()
                }
                self.agentObservation.remoteLastIdentity = agent?.identity
                self.agentObservation.remoteAgent = agent
                guard let agent else {
                    self.clearAutomationAgentStatus()
                    return
                }
                self.presentRemoteAgent(
                    agent, on: destination,
                    isFocused: TerminalManager.automationIsSessionFocused(self.id)
                )
            case .failure(let reason):
                self.agentObservation.remotePolling.failed(reason, at: Date())
                // One interrupted channel can be a panel closing the shared
                // master. Preserve the previous answer until a second failure.
                if self.agentObservation.remotePolling.isUnavailable {
                    self.agentObservation.remoteAgent = nil
                    self.markRemoteAgentUnavailable()
                }
            }
        }
    }

    private func presentRemoteAgent(
        _ agent: RemoteAgent, on destination: RemoteShellDestination, isFocused: Bool
    ) {
        let phase = KeroAgentPhase(
            rawValue: agentObservation.remotePresentation.phase(for: agent, isFocused: isFocused)
        ) ?? .unknown
        let host = RemoteFileService.sanitized(destination.host, maxLines: 1)
        if agentRemoteHost != host { agentRemoteHost = host }
        if agentRemoteIntegration != agent.integration { agentRemoteIntegration = agent.integration }
        let subagents = (agent.state?.subagents ?? []).map { KeroAgentSubagent(id: $0.id, type: $0.type) }
        if agentSubagents != subagents { agentSubagents = subagents }
        let eventVersion = (phase == .done ? agent.state?.turn : agent.state?.revision) ?? 0
        let event = "\(agent.identity):\(phase.rawValue):\(eventVersion)"
        let notify = (phase == .done || phase == .blocked)
            && agentObservation.remoteNotifications.shouldNotify(event: event, at: Date())
        updateAutomationAgentStatus(
            alias: agent.kind.rawValue, kind: agent.kind, phase: phase,
            authority: agent.state == nil ? .process : .integration,
            reason: agent.state == nil ? "Remote agent detected; lifecycle hooks unavailable" : "Remote lifecycle hook",
            processID: nil, unseen: phase == .done, notify: notify
        )
    }

    private func markRemoteAgentUnavailable() {
        guard let previous = agentStatus else { return }
        agentRemoteIntegration = nil
        agentSubagents = []
        updateAutomationAgentStatus(
            alias: previous.alias, kind: previous.kind, phase: .unknown,
            authority: .process, reason: "Remote agent status unavailable",
            processID: nil, unseen: false
        )
    }
}
