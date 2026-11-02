//
//  KeroAgentResume.swift
//  TerminalCore
//

import Darwin
import Foundation

/// The conversation an agent in a pane was running, saved so a relaunch can
/// bring the same conversation back instead of a fresh one.
///
/// The session id ends up as an argument in a command line typed into the
/// restored shell, and it is read from files the agent (or anything else
/// running as the user) writes. It is therefore held to a UUID both on
/// construction and on decoding; a saved pane whose reference fails that
/// check restores as a plain shell (see `PaneSnapshot`).
public nonisolated struct KeroAgentSessionReference: Codable, Equatable, Sendable {
    public let kind: KeroAgentKind
    /// Lowercased UUID string; validated on construction.
    public let sessionID: String
    /// The transcript on disk when the agent revealed it (Codex rollout path),
    /// so a restore can check the conversation still exists.
    public let transcriptPath: String?

    /// Nil unless `sessionID` is a UUID.
    public init?(kind: KeroAgentKind, sessionID: String, transcriptPath: String? = nil) {
        guard KeroAgentResume.isSessionID(sessionID) else { return nil }
        self.kind = kind
        self.sessionID = sessionID.lowercased()
        self.transcriptPath = transcriptPath
    }

    enum CodingKeys: String, CodingKey {
        case kind, sessionID, transcriptPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(KeroAgentKind.self, forKey: .kind)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        let transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        guard let reference = Self(
            kind: kind, sessionID: sessionID, transcriptPath: transcriptPath
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID, in: container,
                debugDescription: "An agent session id must be a UUID"
            )
        }
        self = reference
    }
}

/// Finding the conversation a running agent is in, and the command that
/// resumes it after Terminal relaunches.
///
/// Neither supported agent reports its session id to the terminal, so each is
/// read from where the agent itself keeps it: Claude Code's per-process
/// registry file, and the files Codex holds open for a session's lifetime.
/// Both are keyed to the agent's pid, which is what ties the conversation to
/// the pane rather than to whichever session in the same directory is newest.
public nonisolated enum KeroAgentResume {
    /// The agents whose sessions Terminal knows how to find and resume.
    public static let supportedKinds: [KeroAgentKind] = [.claude, .codex]

    /// Whether `value` is a UUID in its canonical 8-4-4-4-12 hex spelling,
    /// in either case.
    public static func isSessionID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    // MARK: - Claude Code

    /// Where Claude Code's registry for `pid` lives; honors `CLAUDE_CONFIG_DIR`.
    ///
    /// Claude Code writes `<config>/sessions/<pid>.json` while it runs and
    /// deletes it on exit, so the file exists exactly while the pane's agent
    /// does.
    public static func claudeRegistryURL(
        pid: pid_t, homeURL: URL, environment: [String: String]
    ) -> URL {
        claudeConfigURL(homeURL: homeURL, environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json", isDirectory: false)
    }

    /// Directories to look in for a Claude transcript named
    /// `<sessionID>.jsonl`: `<config>/projects`. Transcripts sit one level
    /// down, in a directory named after a slug of the working directory the
    /// session started in; the caller globs that level rather than
    /// reproducing Claude Code's slug rules.
    public static func claudeProjectsURL(homeURL: URL, environment: [String: String]) -> URL {
        claudeConfigURL(homeURL: homeURL, environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Parses the registry; nil unless `pid` matches the file's pid and
    /// `sessionId` is a UUID.
    ///
    /// The pid check guards against a stale file left by a crashed agent
    /// whose pid has since been reused. A `"bg"` session is rejected: it is a
    /// background task the agent launched, not the conversation the user was
    /// looking at in the pane.
    public static func claudeReference(
        registryJSON: Data, pid: pid_t
    ) -> KeroAgentSessionReference? {
        guard let registry = try? JSONDecoder().decode(ClaudeRegistry.self, from: registryJSON),
              registry.pid == Int(pid),
              registry.kind != "bg"
        else { return nil }
        return KeroAgentSessionReference(kind: .claude, sessionID: registry.sessionID)
    }

    // MARK: - Codex

    /// Picks the Codex thread id from a process's open files.
    ///
    /// Codex holds `thread-writer-locks/<uuid>.lock` and the rollout
    /// `sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl` open for a
    /// session's lifetime. The lock names exactly the thread being written,
    /// so it wins; the rollout is the fallback and also supplies
    /// `transcriptPath`. Matching is on the trailing path components because
    /// `CODEX_HOME` can put the whole tree anywhere. When more than one lock
    /// is open, the first in descriptor order is the one opened earliest,
    /// which is the session the pane started.
    ///
    /// This only finds a thread the pane's own process writes, as
    /// `codex exec` does. A TUI whose threads live in the shared app-server
    /// daemon holds none of these files; see `attributeCodexThread`.
    public static func codexReference(openFilePaths: [String]) -> KeroAgentSessionReference? {
        var lockID: String?
        var rollouts: [(id: String, path: String)] = []
        for path in openFilePaths {
            if lockID == nil, let id = codexLockID(path) {
                lockID = id
            } else if let id = codexRolloutID(path) {
                rollouts.append((id, path))
            }
        }

        if let lockID {
            let transcript = rollouts.first { $0.id == lockID }?.path
            return KeroAgentSessionReference(
                kind: .codex, sessionID: lockID, transcriptPath: transcript
            )
        }
        guard let rollout = rollouts.first else { return nil }
        return KeroAgentSessionReference(
            kind: .codex, sessionID: rollout.id, transcriptPath: rollout.path
        )
    }

    // MARK: - Resuming

    /// argv that brings the conversation back, run in the restored shell.
    /// Both agents resume by id from any directory. Empty for a kind outside
    /// `supportedKinds`, whose resume syntax Terminal does not know.
    public static func resumeCommand(_ reference: KeroAgentSessionReference) -> [String] {
        switch reference.kind {
        case .claude:
            return ["claude", "--resume", reference.sessionID]
        case .codex:
            return ["codex", "resume", reference.sessionID]
        default:
            return []
        }
    }

    /// One shell line for `resumeCommand`, every word single-quoted the POSIX
    /// way (`'` becomes `'\''`), so the session id never reaches the shell
    /// unquoted even though it is validated.
    public static func resumeShellLine(_ reference: KeroAgentSessionReference) -> String {
        resumeCommand(reference)
            .map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
            .joined(separator: " ")
    }

    // MARK: - Helpers

    /// The fields of Claude Code's registry this needs; the rest of the file
    /// is ignored so new fields cannot break decoding.
    private struct ClaudeRegistry: Decodable {
        let pid: Int
        let sessionID: String
        let kind: String?

        enum CodingKeys: String, CodingKey {
            case pid, kind
            case sessionID = "sessionId"
        }
    }

    private static func claudeConfigURL(homeURL: URL, environment: [String: String]) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeURL.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The uuid in `…/thread-writer-locks/<uuid>.lock`, lowercased.
    private static func codexLockID(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2,
              components[components.count - 2] == "thread-writer-locks",
              let name = components.last
        else { return nil }
        return lockID(String(name))
    }

    /// The uuid in `…/sessions/…/rollout-<timestamp>-<uuid>.jsonl`, lowercased.
    /// The uuid is the last 36 characters of the name, since the timestamp
    /// before it contains dashes too.
    private static func codexRolloutID(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let name = components.last,
              components.dropLast().contains("sessions"),
              name.hasPrefix("rollout-"), name.hasSuffix(".jsonl")
        else { return nil }
        let stem = name.dropLast(".jsonl".count)
        let id = String(stem.suffix(36))
        guard stem.count > "rollout-".count + 36,
              stem.dropLast(36).hasSuffix("-"),
              isSessionID(id)
        else { return nil }
        return id.lowercased()
    }
}

// MARK: - Codex threads held by a shared daemon

/// A live Codex thread, read from the first line of its rollout.
///
/// Newer Codex installs run every TUI's threads inside one shared
/// `codex app-server` daemon, so the TUI process in a pane holds none of the
/// thread's files and `codexReference(openFilePaths:)` finds nothing. The
/// rollout's `session_meta` header is then the only record of which
/// directory a thread belongs to and when it was created, which is what
/// `attributeCodexThread` matches a pane on.
public nonisolated struct KeroCodexThread: Equatable, Sendable {
    /// Lowercased UUID string; validated on construction.
    public let id: String
    public let rolloutPath: String
    /// The directory the thread was created in, as Codex recorded it.
    public let cwd: String
    public let createdAt: Date
    /// When the rollout was last written. Codex appends on every turn and on
    /// resume, so this is recent for a thread in use even when the thread
    /// itself was created long ago.
    public let modifiedAt: Date
    /// Which Codex front end created the thread, such as `codex-tui` or
    /// `codex_exec`.
    public let originator: String?

    /// Nil unless `id` is a UUID, so every thread converts to a resumable
    /// reference. `modifiedAt` defaults to `createdAt`.
    public init?(
        id: String, rolloutPath: String, cwd: String, createdAt: Date,
        modifiedAt: Date? = nil, originator: String? = nil
    ) {
        guard KeroAgentResume.isSessionID(id) else { return nil }
        self.id = id.lowercased()
        self.rolloutPath = rolloutPath
        self.cwd = cwd
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.originator = originator
    }
}

public nonisolated extension KeroAgentResume {
    /// `$CODEX_HOME` when set and non-empty, else `~/.codex`.
    static func codexHomeURL(homeURL: URL, environment: [String: String]) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The ids of every thread some Codex process is writing right now, from
    /// the `<uuid>.lock` files in `<codexHome>/thread-writer-locks`. Codex
    /// removes a lock when its writer lets go, so the directory lists live
    /// threads only. Anything not named like a lock is ignored.
    static func codexLiveThreadIDs(
        codexHome: URL, fileManager: FileManager = .default
    ) -> [String] {
        let locks = codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: locks.path) else {
            return []
        }
        return names.compactMap(lockID).sorted()
    }

    /// The rollout for `threadID`, found by its `-<id>.jsonl` suffix under
    /// `<codexHome>/sessions/YYYY/MM/DD`.
    ///
    /// Days are searched newest first because a live thread is almost always
    /// recent, and the search stops after 120 day directories so a long
    /// history does not turn one lookup into a walk of the whole archive. A
    /// thread resumed from further back than that is not found, and the
    /// pane simply keeps no reference.
    static func codexRolloutURL(
        threadID: String, codexHome: URL, fileManager: FileManager = .default
    ) -> URL? {
        guard isSessionID(threadID) else { return nil }
        let suffix = "-\(threadID.lowercased()).jsonl"
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)

        var daysSearched = 0
        for year in datedSubdirectories(of: sessions, fileManager: fileManager) {
            for month in datedSubdirectories(of: year, fileManager: fileManager) {
                for day in datedSubdirectories(of: month, fileManager: fileManager) {
                    guard daysSearched < 120 else { return nil }
                    daysSearched += 1
                    let names = (try? fileManager.contentsOfDirectory(atPath: day.path)) ?? []
                    if let name = names.first(where: {
                        $0.hasPrefix("rollout-") && $0.lowercased().hasSuffix(suffix)
                    }) {
                        return day.appendingPathComponent(name, isDirectory: false)
                    }
                }
            }
        }
        return nil
    }

    /// Parses a rollout's first line, its `session_meta` header.
    ///
    /// The header carries the model's base instructions, tens of kilobytes,
    /// and the rest of the file is the whole conversation, so only the first
    /// 64 KiB are read; a header longer than that is not parsed. The read goes
    /// through `readRegularFilePrefix`, so anything but a regular file under
    /// the rollout's name is nil rather than a hang. `cwd` is required.
    /// `createdAt` is the header's own timestamp, falling back to the file's
    /// creation date; `modifiedAt` is the file's. Nil when the first line is
    /// not a `session_meta` record for `id`, so a misnamed file cannot
    /// attribute another thread's directory.
    static func codexThread(
        id: String, rolloutURL: URL, fileManager: FileManager = .default
    ) -> KeroCodexThread? {
        guard let prefix = readRegularFilePrefix(at: rolloutURL, maxBytes: 64 * 1024),
              let newline = prefix.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONDecoder().decode(
                  RolloutHeader.self, from: prefix[prefix.startIndex..<newline]
              ),
              header.type == "session_meta",
              header.payload.id.lowercased() == id.lowercased(),
              !header.payload.cwd.isEmpty
        else { return nil }

        let attributes = try? fileManager.attributesOfItem(atPath: rolloutURL.path)
        guard let createdAt = header.payload.timestamp.flatMap(parseTimestamp)
            ?? attributes?[.creationDate] as? Date
        else { return nil }
        return KeroCodexThread(
            id: id, rolloutPath: rolloutURL.path, cwd: header.payload.cwd,
            createdAt: createdAt, modifiedAt: attributes?[.modificationDate] as? Date,
            originator: header.payload.originator
        )
    }

    /// Every live thread whose rollout can be found and read.
    static func codexLiveThreads(
        codexHome: URL, fileManager: FileManager = .default
    ) -> [KeroCodexThread] {
        codexLiveThreadIDs(codexHome: codexHome, fileManager: fileManager).compactMap { id in
            guard let url = codexRolloutURL(
                threadID: id, codexHome: codexHome, fileManager: fileManager
            ) else { return nil }
            return codexThread(id: id, rolloutURL: url, fileManager: fileManager)
        }
    }

    /// The thread a Codex TUI running in `cwd` since `startedAt` is most
    /// likely in, or nil when none qualifies.
    ///
    /// Codex creates a thread lazily at the first prompt, so a new thread is
    /// never older than its TUI. A thread the user resumed by hand
    /// (`codex resume <id>`) keeps its original creation time, but Codex
    /// appends to its rollout on resume and on every turn, so a thread in use
    /// by this TUI was created or written after it started; whichever is
    /// later must be. Two seconds of slack absorbs the clock granularity
    /// between the kernel's start time and Codex's timestamps.
    /// Directories are compared resolved, because Codex records
    /// `/private/tmp` where the shell says `/tmp`. `claimed` holds threads
    /// already given to other panes. When several still qualify the oldest by
    /// creation wins: two TUIs in one directory are prompted in the order
    /// they were started, and the caller assigns panes in that same order.
    static func attributeCodexThread(
        threads: [KeroCodexThread], cwd: String, startedAt: Date, claimed: Set<String>
    ) -> KeroCodexThread? {
        let directory = resolvedDirectory(cwd)
        let earliest = startedAt.addingTimeInterval(-2)
        return threads
            .filter {
                !claimed.contains($0.id) && max($0.createdAt, $0.modifiedAt) >= earliest
                    && resolvedDirectory($0.cwd) == directory
            }
            .min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The resumable reference for a thread.
    static func reference(for thread: KeroCodexThread) -> KeroAgentSessionReference {
        // `KeroCodexThread`'s initializer already rejected a non-UUID id, the
        // only thing that fails this one.
        KeroAgentSessionReference(
            kind: .codex, sessionID: thread.id, transcriptPath: thread.rolloutPath
        )!
    }

    /// The fields of a rollout's first line this needs. Unknown fields,
    /// including the large base instructions, are skipped by the decoder.
    private struct RolloutHeader: Decodable {
        struct Payload: Decodable {
            let id: String
            let cwd: String
            let timestamp: String?
            let originator: String?
        }

        let type: String
        let payload: Payload
    }

    private static func lockID(_ name: String) -> String? {
        guard name.hasSuffix(".lock") else { return nil }
        let id = String(name.dropLast(".lock".count))
        return isSessionID(id) ? id.lowercased() : nil
    }

    /// The all-digit subdirectories of `url`, newest first. The sessions tree
    /// is zero-padded year, month, and day, so a descending string sort is a
    /// descending date sort.
    private static func datedSubdirectories(of url: URL, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            .sorted(by: >)
            .map { url.appendingPathComponent($0, isDirectory: true) }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }

    private static func resolvedDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
