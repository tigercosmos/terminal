//
//  GitStatusModel.swift
//  TerminalCore
//

import Combine
import Dispatch
import Foundation

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
public final class GitStatusModel: nonisolated ObservableObject {
    nonisolated public struct Entry: Identifiable, Equatable, Sendable {
        public var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        public let path: String
        /// Index (staged) status letter, "." when clean, "?" for untracked.
        public let staged: Character
        /// Worktree (unstaged) status letter.
        public let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        public var origPath: String?
        /// Canonical repo that produced this snapshot. Mutations reject stale
        /// rows after the active terminal moves to another repository.
        public var repositoryRoot = ""

        public var fileName: String { (path as NSString).lastPathComponent }
        public var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        /// Intent-to-add (`git add -N`) is represented as `.A`; restoring it
        /// from the empty index blob would truncate user content, so destructive
        /// handling treats it like an untracked file and uses the Trash.
        var isIntentToAdd: Bool { staged == "." && unstaged == "A" }
        public var isUntracked: Bool { staged == "?" || isIntentToAdd }
        public var isWorktreeRename: Bool { unstaged == "R" && origPath != nil }
        public var isWorktreeCopy: Bool { unstaged == "C" && origPath != nil }

        // A file can sit in two sections at once (for example, "MM"). Rows in
        // the same lazy stack need distinct identities or SwiftUI drops one.
        public var mergeRowID: String { "merge/" + path }
        public var stagedRowID: String { "staged/" + path }
        public var changedRowID: String { "changed/" + path }
    }

    /// Compact Explorer-style decoration for a path in the active repository.
    /// The file tree maps these semantic states to both a color and a visible
    /// status badge, so color is never the only indication.
    nonisolated public enum FileDecoration: Equatable, Sendable {
        case modified
        case added
        case untracked
        case deleted
        case renamed
        case copied
        case conflict
        case ignored

        /// When a directory contains several changed files, bubble up the
        /// state that most needs attention.
        var directoryPriority: Int {
            switch self {
            case .conflict: 8
            case .deleted: 7
            case .modified: 6
            case .added: 5
            case .untracked: 4
            case .renamed: 3
            case .copied: 2
            case .ignored: 1
            }
        }
    }

    nonisolated public struct RecentCommit: Identifiable, Equatable, Sendable {
        public var id: String { hash }
        public let hash: String
        public let shortHash: String
        public let subject: String
        public let author: String
        let date: Date

        public var relativeDate: String {
            date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    nonisolated public struct Operation: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(exitCode: Int32)
        }

        public let id: UUID
        let label: String
        public var state: State
        public var output: String
        let startedAt: Date
        var finishedAt: Date?

        public var isRunning: Bool { state == .running }
        var isSuccess: Bool { state == .succeeded }

        public var statusLabel: String {
            switch state {
            case .running:
                return String(localized: "\(label)…", bundle: .module, comment: "A Git operation that is still running.")
            case .succeeded:
                return String(localized: "\(label) completed", bundle: .module, comment: "A Git operation that completed successfully.")
            case .failed:
                return String(localized: "\(label) failed", bundle: .module, comment: "A Git operation that failed.")
            }
        }
    }

    @Published public private(set) var rootPath = ""
    /// Where the panel has been pointed, and on which machine.
    @Published public private(set) var panelRoot = PanelRoot.local("")
    /// Stable canonical repository root, used by the UI to key drafts. It is
    /// preserved while a cwd change is being resolved inside the same repo.
    @Published public private(set) var repositoryIdentity = ""
    @Published public private(set) var isRepo = false
    @Published public private(set) var fileDecorations: [String: FileDecoration] = [:]
    /// Relative porcelain paths. Directory records retain their trailing slash
    /// so expanded descendants can inherit the ignored state.
    @Published public private(set) var ignoredPaths: Set<String> = []
    @Published public private(set) var branch: String?
    @Published public private(set) var headOID: String?
    @Published public private(set) var hasHead = true
    @Published public private(set) var upstream: String?
    @Published public private(set) var ahead = 0
    @Published public private(set) var behind = 0
    @Published public private(set) var hasUpstream = false
    @Published public private(set) var lineAdditions = 0
    @Published public private(set) var lineDeletions = 0
    @Published public private(set) var mergeEntries: [Entry] = []
    @Published public private(set) var stagedEntries: [Entry] = []
    @Published public private(set) var changedEntries: [Entry] = []
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var defaultBranch: String?
    @Published public private(set) var remotes: [String] = []
    @Published public private(set) var recentCommits: [RecentCommit] = []
    @Published public private(set) var repositoryOperation: String?
    @Published public private(set) var stashCount = 0
    @Published public private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    @Published public private(set) var hasResolvedStatus = false
    @Published public private(set) var statusError: String?
    /// True while a user-initiated Git operation runs.
    @Published public private(set) var isBusy = false
    @Published public private(set) var operation: Operation?
    @Published public var lastError: String?

    public init() {}

    /// Absolute repository root. Porcelain paths are relative to this path,
    /// not necessarily to the terminal's current working directory.
    private var topLevel = ""
    /// Invalidates async refreshes and operations after the terminal changes cwd.
    private var contextGeneration: UInt = 0
    /// Invalidates an in-flight status refresh when a mutation begins, so its
    /// pre-operation snapshot cannot overwrite the post-operation state.
    private var statusRequestID: UInt = 0
    /// Coalesces an event that arrives while another refresh or mutation is
    /// running. Without polling, dropping that event could leave the snapshot
    /// stale indefinitely.
    private var refreshPending = false
    /// When the last status load finished, for the remote polling interval.
    private var lastLoad: Date?
    /// Restores a previously resolved directory immediately when switching
    /// tabs. Without this, every return to a repository clears `isRepo` until
    /// the asynchronous Git refresh finishes, briefly removing the toolbar
    /// and resizing the terminal through the wrong height.
    private var cachedStatusByRoot: [PanelRoot: StatusLoadResult] = [:]
    /// Keeps a mutation globally exclusive even if the terminal changes cwd
    /// while its Git process is still running.
    private var runningOperationID: UUID?
    public var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// True while the first status load for the current directory is still in
    /// flight, so later event-driven refreshes do not replace resolved content
    /// with a loading state.
    public var isResolvingInitialStatus: Bool {
        isRefreshing && !hasResolvedStatus
    }

    public var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    /// The ssh connection the repository sits behind, when the terminal has
    /// followed one onto another machine. Nil for a repository on this Mac.
    public var remote: RemoteShellDestination? { panelRoot.remote }

    /// The repository, and the machine it is on. Everything the panel runs goes
    /// through this rather than through ``repoRoot`` alone.
    public var repoDirectory: GitDirectory {
        GitDirectory(repoRoot, on: remote)
    }

    /// The directory the panel was pointed at, before Git resolved which
    /// repository contains it.
    var rootDirectory: GitDirectory {
        GitDirectory(rootPath, on: remote)
    }

    /// True when the panel is looking wherever an ssh command lands because the
    /// remote shell has never said where it is. The repository the user is
    /// actually in will not be found from there unless it happens to be the
    /// login directory, so the panel says so rather than reporting no
    /// repository at all.
    public var isSearchingRemoteLoginDirectory: Bool {
        panelRoot.isRemoteLoginFallback && !isRepo
    }

    /// The host whose repository is shown, when it is not this machine's.
    public var remoteHost: String? { remote?.host }

    /// Whether Terminal can act on this repository from the panel.
    ///
    /// A remote repository is read-only, exactly as the remote file tree is:
    /// what the Git actions ultimately reach for — the Trash for a discarded
    /// untracked file, a credential helper for a push — is on this Mac and
    /// belongs to a different machine's checkout.
    public var isEditable: Bool { remote == nil }

    /// What the panel calls the directory it is describing, host-qualified when
    /// the repository is on another machine.
    public var displayPath: String {
        GitDirectory(isRepo ? repoRoot : rootPath, on: remote).displayPath
    }

    public func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    public func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    public func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let repositoryPath = (topLevel as NSString).standardizingPath
        let itemPath = (absolutePath as NSString).standardizingPath
        let relativePath: String
        if itemPath == repositoryPath {
            relativePath = ""
        } else {
            let prefix = repositoryPath + "/"
            guard itemPath.hasPrefix(prefix) else { return nil }
            relativePath = String(itemPath.dropFirst(prefix.count))
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(where: { ignoredPath in
            if ignoredPath.hasSuffix("/") {
                let directory = String(ignoredPath.dropLast())
                return relativePath == directory || relativePath.hasPrefix(directory + "/")
            }
            return relativePath == ignoredPath
        }) {
            return .ignored
        }
        guard isDirectory, !relativePath.isEmpty else { return nil }

        let descendantPrefix = relativePath + "/"
        return fileDecorations
            .filter { $0.key.hasPrefix(descendantPrefix) }
            .map(\.value)
            .max { $0.directoryPriority < $1.directoryPriority }
    }

    /// Points the panel at `root`, on this Mac or on the host a terminal has
    /// ssh'd into. Changing machine is not a cwd change inside one repository,
    /// so it drops the identity a draft was keyed to rather than preserving it.
    ///
    /// `polling` marks a tick from the panel's timer rather than something the
    /// user did; see ``refreshIfStale()``.
    public func sync(root: PanelRoot, polling: Bool = false) {
        var moved = false
        if root != panelRoot {
            let sameMachine = root.remote == panelRoot.remote
            contextGeneration &+= 1
            panelRoot = root
            // The best name available now, so the header is not blank while the
            // host is asked to place it; the load replaces it with what it
            // actually read.
            rootPath = root.provisionalPath
            hasResolvedStatus = false
            clearRepositoryState(preserveIdentity: sameMachine)
            if let cachedStatus = cachedStatusByRoot[root] {
                apply(cachedStatus)
                hasResolvedStatus = true
            }
            moved = true
        }
        if polling && !moved {
            refreshIfStale()
        } else {
            refresh()
        }
    }

    /// How long a remote snapshot is trusted before the panel's next tick
    /// re-reads it. Long enough that leaving the panel open is not a command a
    /// second on the other machine, short enough that work an agent does there
    /// shows up while the user is still looking at it.
    private static let remoteRefreshInterval: TimeInterval = 5

    /// A tick from the panel's timer.
    ///
    /// Only a repository on another machine is polled at all. A local one has
    /// events to refresh on — a terminal command finishing, the app coming
    /// forward — but a terminal sitting inside `ssh` finishes no commands until
    /// the user comes back out of it, so those events never arrive and the
    /// panel would go stale for as long as the connection lasted.
    private func refreshIfStale() {
        guard remote != nil else { return }
        if let lastLoad, Date().timeIntervalSince(lastLoad) < Self.remoteRefreshInterval {
            return
        }
        refresh()
    }

    public func refresh() {
        let root = panelRoot
        let generation = contextGeneration
        guard !root.isUnset else { return }
        guard !isRefreshing, !isBusy else {
            refreshPending = true
            return
        }
        refreshPending = false
        statusRequestID &+= 1
        let requestID = statusRequestID
        isRefreshing = true

        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                // Resolving the directory can mean asking the host where its
                // login lands, or whether it answers to the name a shell
                // reported — neither of which the main actor can wait on.
                let directory = root.directory()
                return (directory: directory, result: Self.runGitStatus(in: directory))
            }.value
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.panelRoot == root else { return }
            self.isRefreshing = false
            self.lastLoad = Date()
            self.rootPath = loaded.directory.path
            switch loaded.result {
            case .repository, .notRepository:
                self.cachedStatusByRoot[root] = loaded.result
            case .failed:
                break
            }
            self.apply(loaded.result)
            self.hasResolvedStatus = true
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    public func dismissOperation() {
        guard operation?.isRunning != true else { return }
        operation = nil
        lastError = nil
    }

    // MARK: - File operations

    public func stage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        perform(
            label: String(localized: "Stage \(entry.fileName)", bundle: .module),
            commands: [["--literal-pathspecs", "add", "--"] + paths]
        )
    }

    public func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: String(localized: "Unstage \(entry.fileName)", bundle: .module), commands: [args])
    }

    public func stageAll() {
        perform(label: String(localized: "Stage all changes", bundle: .module), commands: [["add", "-A"]])
    }

    public func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: String(localized: "Unstage all changes", bundle: .module), commands: [args])
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    public func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: String(localized: "Remove intent-to-add for \(entry.fileName)", bundle: .module),
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash", bundle: .module),
                    completedBefore: String(localized: "Removed the intent-to-add index entry.", bundle: .module)
                )
            }
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(
                paths: [entry.path],
                label: String(localized: "Move \(entry.fileName) to Trash", bundle: .module)
            )
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: String(localized: "Restore \((original as NSString).lastPathComponent)", bundle: .module),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash", bundle: .module),
                    completedBefore: String(localized: "Restored \((original as NSString).lastPathComponent).", bundle: .module)
                )
            }
        } else {
            perform(
                label: String(localized: "Discard changes in \(entry.fileName)", bundle: .module),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]]
            )
        }
    }

    /// Discards every worktree change. Tracked files are restored and
    /// untracked files are moved to the Trash. The UI confirms first.
    func discardAllChanges() {
        discardChanges(changedEntries)
    }

    /// Discards only the confirmed snapshot. This prevents new files written
    /// by an agent while the dialog is open from joining a bulk destructive action.
    public func discardChanges(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        guard entries.allSatisfy(isCurrent) else {
            cancelStaleDiscard()
            return
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter { $0.isWorktreeRename || $0.isWorktreeCopy }
        let untracked = entries.filter(\.isUntracked).map(\.path) + moved.map(\.path)
        let renamedOriginals = moved.filter(\.isWorktreeRename).compactMap(\.origPath)
        let tracked = entries.filter {
            !$0.isUntracked && !$0.isWorktreeRename && !$0.isWorktreeCopy
        }.map(\.path) + renamedOriginals
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked)
        }
        if !intentToAdd.isEmpty {
            commands.append(
                ["--literal-pathspecs", "rm", "--cached", "-f", "--"]
                    + intentToAdd.map(\.path)
            )
        }
        guard !commands.isEmpty || !untracked.isEmpty else { return }

        if commands.isEmpty {
            trash(paths: untracked, label: String(localized: "Move untracked files to Trash", bundle: .module))
        } else {
            var completedSteps: [String] = []
            if !tracked.isEmpty {
                completedSteps.append(
                    String(localized: "Restored \(tracked.count) tracked paths.", bundle: .module)
                )
            }
            if !intentToAdd.isEmpty {
                completedSteps.append(
                    String(localized: "Removed \(intentToAdd.count) intent-to-add index entries.", bundle: .module)
                )
            }
            perform(label: String(localized: "Discard all changes", bundle: .module), commands: commands) { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: String(localized: "Finish discarding all changes", bundle: .module),
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            }
        }
    }

    public func cancelStaleDiscard() {
        failImmediately(String(localized: "Files changed while the confirmation was open. Review them and try again.", bundle: .module))
    }

    // MARK: - Commit and remote operations

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    public func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a commit message", bundle: .module), completion: completion)
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately(String(localized: "Stage changes before committing", bundle: .module), completion: completion)
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend
            ? String(localized: "Amend commit", bundle: .module)
            : (includeAll
                ? String(localized: "Stage all and commit", bundle: .module)
                : String(localized: "Commit staged changes", bundle: .module))
        perform(label: label, commands: commands, completion: completion)
    }

    /// Compatibility for older call sites. The behavior remains explicit in
    /// the new panel, which uses the overload above.
    public func commit(message: String) {
        commit(message: message, includeAll: stagedEntries.isEmpty)
    }

    public func fetch() {
        guard !remotes.isEmpty else {
            failImmediately(String(localized: "No Git remote is configured", bundle: .module))
            return
        }
        perform(
            label: String(localized: "Fetch", bundle: .module),
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    public func pull() {
        guard hasUpstream else {
            failImmediately(String(localized: "This branch has no upstream to pull from", bundle: .module))
            return
        }
        perform(
            label: String(localized: "Pull", bundle: .module),
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    public func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", bundle: .module))
            return
        }
        if hasUpstream {
            perform(label: String(localized: "Push", bundle: .module), commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? String(localized: "Add a Git remote before publishing this branch", bundle: .module)
                : String(localized: "Choose which remote should receive this branch", bundle: .module))
            return
        }
        perform(label: String(localized: "Publish branch", bundle: .module), commands: [["push", "-u", remote, "HEAD"]])
    }

    public func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", bundle: .module))
            return
        }
        guard remotes.contains(remote) else {
            failImmediately(String(localized: "The selected Git remote is no longer available", bundle: .module))
            return
        }
        perform(
            label: String(localized: "Publish branch to \(remote)", bundle: .module),
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    public func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", bundle: .module))
            return
        }
        if hasUpstream {
            perform(
                label: String(localized: "Sync changes", bundle: .module),
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? String(localized: "Add a Git remote before publishing this branch", bundle: .module)
                    : String(localized: "Choose which remote should receive this branch", bundle: .module))
                return
            }
            perform(label: String(localized: "Publish branch", bundle: .module), commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    public func switchBranch(to name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !name.isEmpty, name != branch else {
            completion?(name == branch)
            return
        }
        perform(
            label: String(localized: "Switch to \(name)", bundle: .module),
            commands: [["switch", name]],
            completion: completion
        )
    }

    public func createBranch(named name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a branch name", bundle: .module), completion: completion)
            return
        }
        perform(
            label: String(localized: "Create branch \(trimmed)", bundle: .module),
            commands: [["switch", "-c", trimmed]],
            completion: completion
        )
    }

    public func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately(String(localized: "There are no changes to stash", bundle: .module))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: String(localized: "Stash changes", bundle: .module), commands: [args])
    }

    public func stashPop() {
        guard stashCount > 0 else {
            failImmediately(String(localized: "There are no stashes to pop", bundle: .module))
            return
        }
        perform(label: String(localized: "Pop stash", bundle: .module), commands: [["stash", "pop"]])
    }

    public func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(String(localized: "Open a terminal directory first", bundle: .module), completion: completion)
            return
        }
        perform(
            label: String(localized: "Initialize repository", bundle: .module),
            commands: [["init"]],
            directory: rootPath,
            completion: completion
        )
    }

    // MARK: - Operation runner

    private var unambiguousRemote: String? {
        remotes.count == 1 ? remotes[0] : nil
    }

    private func validate(_ entry: Entry) -> Bool {
        guard isCurrent(entry) else {
            failImmediately(String(localized: "Repository changed; refresh and try the Git action again", bundle: .module))
            return false
        }
        return true
    }

    /// Refuses an action against a repository on another machine.
    ///
    /// Checked here rather than trusting the panel to have hidden the button:
    /// every one of these commands writes, and the panel can be looking at a
    /// remote repository one refresh after it was looking at a local one.
    private func validateEditable(
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard !isEditable else { return true }
        failImmediately(
            String(localized: "This repository is on \(remoteHost ?? ""), which Terminal shows but does not change.", bundle: .module),
            completion: completion
        )
        return false
    }

    private func perform(
        label: String,
        commands: [[String]],
        directory: String? = nil,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard validateEditable(completion: completion) else { return }
        if directory == nil && !isRepo {
            failImmediately(
                String(localized: "Repository changed; review the current directory and try the Git action again.", bundle: .module),
                completion: completion
            )
            return
        }
        let dir = directory ?? repoRoot
        let generation = contextGeneration
        let validationRoot = rootDirectory
        // Carried rather than rebuilt as a bare local path: `validateEditable`
        // is what keeps these off another machine, and a directory that quietly
        // dropped its host would turn a bypass of that guard into a local `git`
        // running at a path only the remote host has.
        let commandDirectory = validationRoot.directory(dir)
        let expectedRepositoryRoot = directory == nil && isRepo ? repoRoot : nil
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let expectedUpstream = upstream
        guard !dir.isEmpty, !isBusy, !commands.isEmpty else { return }

        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID,
            label: label,
            state: .running,
            output: "",
            startedAt: Date(),
            finishedAt: nil
        )

        Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?

                if let expectedRepositoryRoot {
                    guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                        let message = String(localized: "Repository changed before the Git action could run. Review the current changes and try again.", bundle: .module)
                        return CommandBatchResult(
                            output: message, failureCode: -1, failureMessage: message
                        )
                    }
                    if requiresStableHead {
                        let liveStatus = GitCommand.run(
                            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                            in: validationRoot.directory(expectedRepositoryRoot)
                        )
                        let live = liveStatus.status == 0
                            ? Self.parseStatus(liveStatus.stdout)
                            : nil
                        guard let live,
                              live.headOID == expectedHeadOID,
                              live.branch == expectedBranch,
                              !requiresStableUpstream || live.upstream == expectedUpstream else {
                            let message = requiresStableUpstream
                                ? String(localized: "Branch, HEAD, or upstream changed before the Git action could run. Review the current changes and try again.", bundle: .module)
                                : String(localized: "Branch or HEAD changed before the Git action could run. Review the current changes and try again.", bundle: .module)
                            return CommandBatchResult(
                                output: message, failureCode: -1, failureMessage: message
                            )
                        }
                    }
                }

                for args in commands {
                    transcript.append("$ git " + Self.displayCommand(args))
                    // The user asked for this command, so the repository's own
                    // hooks (pre-commit, post-checkout, …) must run normally.
                    let run = GitCommand.run(
                        args, in: commandDirectory, allowingRepositoryHooks: true
                    )
                    let text = [run.stdout, run.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    if !text.isEmpty { transcript.append(text) }
                    if run.status != 0 {
                        let fallback = String(localized: "Git command failed", bundle: .module)
                        failureCode = run.status
                        failureMessage = text.isEmpty ? fallback : text
                        break
                    }
                }
                return CommandBatchResult(
                    output: transcript.joined(separator: "\n"),
                    failureCode: failureCode,
                    failureMessage: failureMessage
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                // The command may have completed in the old repository, but
                // success-only follow-ups (for example moving a renamed file
                // to Trash) must never continue in the newly selected context.
                completion?(false)
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failureCode = batch.failureCode {
                self.lastError = batch.failureMessage
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .failed(exitCode: failureCode),
                    output: batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(false)
            } else {
                self.lastError = nil
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .succeeded,
                    output: batch.output.isEmpty
                        ? String(localized: "Completed successfully.", bundle: .module)
                        : batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(true)
            }
            self.refresh()
        }
    }

    private func failImmediately(
        _ message: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }
        lastError = message
        operation = Operation(
            id: UUID(),
            label: String(localized: "Git action", bundle: .module),
            state: .failed(exitCode: -1),
            output: message,
            startedAt: Date(),
            finishedAt: Date()
        )
        completion?(false)
    }

    private func trash(paths: [String], label: String, completedBefore: String? = nil) {
        guard validateEditable() else { return }
        guard !paths.isEmpty, !isBusy else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let expectedRepositoryRoot = repoRoot
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let validationRoot = rootDirectory
        let generation = contextGeneration
        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID, label: label, state: .running, output: "",
            startedAt: Date(), finishedAt: nil
        )

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard Self.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Repository changed before the file action could run. Review the current changes and try again.", bundle: .module)
                    )
                }
                let liveStatus = GitCommand.run(
                    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    in: validationRoot.directory(expectedRepositoryRoot)
                )
                let live = liveStatus.status == 0 ? Self.parseStatus(liveStatus.stdout) : nil
                guard let live,
                      live.headOID == expectedHeadOID,
                      live.branch == expectedBranch else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Branch or HEAD changed before the file action could run. Review the current changes and try again.", bundle: .module)
                    )
                }
                var moved: [String] = []
                var failure: String?
                for path in paths {
                    do {
                        try FileManager.default.trashItem(
                            at: base.appendingPathComponent(path), resultingItemURL: nil
                        )
                        moved.append(path)
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                return TrashResult(moved: moved, failure: failure)
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failure = result.failure {
                let completedResult = completedBefore.map { $0 + "\n" } ?? ""
                let partialResult = result.moved.isEmpty
                    ? ""
                    : "\n\n" + String(localized: "Moved to Trash before the failure:", bundle: .module) + "\n"
                        + result.moved.joined(separator: "\n")
                let output = completedResult + failure + partialResult
                self.lastError = result.moved.isEmpty
                    ? completedResult + failure
                    : completedResult + String(
                        localized: "\(failure) (\(result.moved.count) items were already moved to Trash.)", bundle: .module
                    )
                self.operation = Operation(
                    id: operationID, label: label, state: .failed(exitCode: -1),
                    output: output, startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            } else {
                let output = [
                    completedBefore,
                    String(localized: "Moved to Trash:", bundle: .module) + "\n"
                        + result.moved.joined(separator: "\n"),
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                self.operation = Operation(
                    id: operationID, label: label, state: .succeeded,
                    output: output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            }
            self.refresh()
        }
    }

    private nonisolated struct CommandBatchResult: Sendable {
        public let output: String
        let failureCode: Int32?
        let failureMessage: String?
    }

    private nonisolated struct TrashResult: Sendable {
        let moved: [String]
        let failure: String?
    }

    private nonisolated final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    private func invalidateStatusRefresh() {
        statusRequestID &+= 1
        isRefreshing = false
        refreshPending = false
    }

    private nonisolated static func displayCommand(_ args: [String]) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        return args.map { arg in
            guard arg.isEmpty || arg.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Status

    private func clearRepositoryState(
        preserveIdentity: Bool = false,
        preserveFailedOperation: Bool = false
    ) {
        let failedOperation = preserveFailedOperation ? operation : nil
        let failedError = preserveFailedOperation ? lastError : nil
        topLevel = ""
        isRepo = false
        branch = nil
        headOID = nil
        hasHead = true
        upstream = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        lineAdditions = 0
        lineDeletions = 0
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        fileDecorations = [:]
        ignoredPaths = []
        branches = []
        remotes = []
        recentCommits = []
        repositoryOperation = nil
        stashCount = 0
        isRefreshing = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ loadResult: StatusLoadResult) {
        switch loadResult {
        case .notRepository:
            // A refresh can finish after a user action starts. Do not let a
            // transient status failure erase the active operation/result.
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            return
        case .failed(let message):
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(
                preserveIdentity: true,
                preserveFailedOperation: preserveFailure
            )
            statusError = message
            return
        case .repository(let result):
            statusError = nil
            applyRepository(result)
        }
    }

    private func applyRepository(_ result: StatusResult) {
        isRepo = true
        branch = result.branch
        headOID = result.headOID
        hasHead = result.hasHead
        upstream = result.upstream
        ahead = result.ahead
        behind = result.behind
        hasUpstream = result.upstream != nil
        lineAdditions = result.lineAdditions
        lineDeletions = result.lineDeletions
        topLevel = result.topLevel
        // Host-qualified: the same path names a different repository on a
        // different machine, and this is what the panel keys a commit message
        // draft to.
        repositoryIdentity = GitDirectory(result.topLevel, on: remote).displayPath
        if result.loadedDetails {
            branches = result.branches
            defaultBranch = result.defaultBranch
            remotes = result.remotes
            recentCommits = result.recentCommits
            repositoryOperation = result.repositoryOperation
            stashCount = result.stashCount
        }

        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            return entry
        }
        fileDecorations = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.path, Self.fileDecoration(for: $0)) }
        )
        ignoredPaths = result.ignoredPaths
        mergeEntries = entries.filter(\.isConflict)
        stagedEntries = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        changedEntries = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
    }

    nonisolated enum StatusLoadResult: Equatable, Sendable {
        case repository(StatusResult)
        case notRepository
        case failed(String)
    }

    nonisolated struct StatusResult: Equatable, Sendable {
        public var branch: String?
        var headOID: String?
        var hasHead = true
        var upstream: String?
        var ahead = 0
        var behind = 0
        var lineAdditions = 0
        var lineDeletions = 0
        var topLevel = ""
        public var entries: [Entry] = []
        var ignoredPaths: Set<String> = []
        var branches: [String] = []
        var defaultBranch: String?
        var remotes: [String] = []
        public var recentCommits: [RecentCommit] = []
        var repositoryOperation: String?
        var stashCount = 0
        var loadedDetails = false
    }

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    private nonisolated static func runGitStatus(in root: GitDirectory) -> StatusLoadResult {
        let top = GitCommand.run(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let failure = gitFailureMessage(
                top,
                fallback: String(localized: "Unable to locate the Git repository.", bundle: .module)
            )
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !containsGitMetadata(atOrAbove: root) {
                return .notRepository
            }
            return .failed(failure)
        }
        let resolvedRoot = strippingTrailingLineEnding(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path.", bundle: .module))
        }
        let repoRoot = root.directory(resolvedRoot)
        let status = GitCommand.run(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            in: repoRoot
        )
        guard status.status == 0 else {
            return .failed(
                gitFailureMessage(
                    status,
                    fallback: String(localized: "Unable to read Git status.", bundle: .module)
                )
            )
        }
        var result = parseStatus(status.stdout)
        result.topLevel = resolvedRoot

        let diff = GitCommand.run(
            result.hasHead
                ? ["diff", "--numstat", "HEAD", "--"]
                : ["diff", "--numstat", "--cached", "--"],
            in: repoRoot
        )
        if diff.status == 0 {
            let totals = parseNumstat(diff.stdout)
            result.lineAdditions = totals.additions
            result.lineDeletions = totals.deletions
        }
        // An unborn branch has no HEAD to compare against. Its cached diff is
        // the initial snapshot; add any edits made after staging as a second
        // layer so the toolbar still reflects all pending work.
        if !result.hasHead {
            let unstaged = GitCommand.run(["diff", "--numstat", "--"], in: repoRoot)
            if unstaged.status == 0 {
                let totals = parseNumstat(unstaged.stdout)
                result.lineAdditions += totals.additions
                result.lineDeletions += totals.deletions
            }
        }
        // `git diff` intentionally omits untracked files. Count their text
        // lines as additions so the compact toolbar totals cover all pending
        // work reported by the porcelain snapshot. Only on this Mac: reading
        // a remote checkout would mean a round trip per file, and these paths
        // name files on the other machine, not here.
        if repoRoot.isLocal {
            result.lineAdditions += untrackedLineAdditions(
                for: result.entries,
                in: resolvedRoot
            )
        }

        result.loadedDetails = true

        let refs = GitCommand.run(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repoRoot
        )
        if refs.status == 0 {
            result.branches = refs.stdout.split(separator: "\n").map(String.init).sorted()
        }

        let remoteRun = GitCommand.run(["remote"], in: repoRoot)
        if remoteRun.status == 0 {
            result.remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
        }

        // A clone records its remote's default branch as a symbolic HEAD.
        // Prefer origin when more than one remote is present because that is
        // the repository the local branch list conventionally belongs to.
        if let remoteName = result.remotes.contains("origin") ? "origin" : result.remotes.first {
            let remoteHead = GitCommand.run(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remoteName)/HEAD"],
                in: repoRoot
            )
            let prefix = "\(remoteName)/"
            let ref = strippingTrailingLineEnding(remoteHead.stdout)
            if remoteHead.status == 0, ref.hasPrefix(prefix) {
                let branch = String(ref.dropFirst(prefix.count))
                if result.branches.contains(branch) {
                    result.defaultBranch = branch
                }
            }
        }

        let log = GitCommand.run(
            ["log", "-n", "8", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"],
            in: repoRoot
        )
        if log.status == 0 { result.recentCommits = parseRecentCommits(log.stdout) }

        let stash = GitCommand.run(
            ["rev-list", "--walk-reflogs", "--count", "refs/stash"], in: repoRoot
        )
        if stash.status == 0 {
            result.stashCount = Int(stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let gitDir = GitCommand.run(["rev-parse", "--absolute-git-dir"], in: repoRoot)
        if gitDir.status == 0 {
            let path = strippingTrailingLineEnding(gitDir.stdout)
            result.repositoryOperation = detectRepositoryOperation(
                gitDirectory: root.directory(path)
            )
        }
        return .repository(result)
    }

    private nonisolated static func resolveRepositoryRoot(in root: GitDirectory) -> String? {
        let top = GitCommand.run(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else { return nil }
        let path = strippingTrailingLineEnding(top.stdout)
        return path.isEmpty ? nil : path
    }

    /// A malformed `.git` directory/file can produce the same rev-parse text
    /// as a plain folder. Preserve that as an actionable status error instead
    /// of offering to initialize a nested repository on top of broken metadata.
    ///
    /// Only ever asked of a directory on this machine: walking a remote tree
    /// would be a round trip per level, and the panel offers no "Initialize
    /// Repository" button there for the answer to change.
    private nonisolated static func containsGitMetadata(atOrAbove root: GitDirectory) -> Bool {
        guard root.isLocal else { return false }
        let fm = FileManager.default
        // Walk path strings, not URLs: `URL.deletingLastPathComponent()` keeps
        // appending ".." at the filesystem root, so a URL ascent never
        // reaches its fixed point and spins forever. The NSString walk
        // terminates at "/".
        var directory = URL(fileURLWithPath: root.path, isDirectory: true)
            .standardizedFileURL.path as NSString
        while true {
            if fm.fileExists(atPath: directory.appendingPathComponent(".git")) {
                return true
            }
            let parent = directory.deletingLastPathComponent as NSString
            if parent.isEqual(to: directory as String) { return false }
            directory = parent
        }
    }

    private nonisolated static func strippingTrailingLineEnding(_ value: String) -> String {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    /// Git's own diagnostic for a failed command, made safe to show.
    ///
    /// Sanitized because this is the one place Git's output stops being parsed
    /// and starts being displayed. `GitCommand` cleans a remote command's
    /// stderr, but not its stdout — that is where the porcelain records live,
    /// and stripping control characters out of those would corrupt the very
    /// NUL-delimited framing the parsers rely on. So it happens here instead,
    /// on the string that actually reaches the panel, and for a local
    /// repository too: a branch name holding an escape sequence should not be
    /// able to redraw the error it appears in.
    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String), fallback: String
    ) -> String {
        let message = [run.stderr, run.stdout]
            .lazy
            .map { RemoteFileService.sanitized($0, maxLines: 8) }
            .first { !$0.isEmpty }
        return message ?? fallback
    }

    /// Adds the numeric columns from `git diff --numstat`. Binary-file rows
    /// use `-` instead of a count and therefore contribute zero lines.
    nonisolated static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { total, row in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            total.additions += Int(fields[0]) ?? 0
            total.deletions += Int(fields[1]) ?? 0
        }
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseStatus(_ output: String) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                result.hasHead = oid != "(initial)"
                result.headOID = result.hasHead ? oid : nil
            } else if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                if fields.count == 9, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1])
                    )
                }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                if fields.count == 10, fields[1].count == 2, index + 1 < records.count {
                    let xy = Array(fields[1])
                    // With -z, the destination is in this record and the
                    // original path is the following NUL-delimited token.
                    result.entries.append(
                        Entry(
                            path: String(fields[9]), staged: xy[0], unstaged: xy[1],
                            origPath: records[index + 1]
                        )
                    )
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                if fields.count == 11, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        Entry(
                            path: String(fields[10]), staged: xy[0], unstaged: xy[1],
                            isConflict: true
                        )
                    )
                }
            } else if record.hasPrefix("? ") {
                result.entries.append(
                    Entry(path: String(record.dropFirst(2)), staged: "?", unstaged: "?")
                )
            } else if record.hasPrefix("! ") {
                result.ignoredPaths.insert(String(record.dropFirst(2)))
            }
            index += 1
        }
        return result
    }

    /// Git's numstat output has no representation for untracked files. Mirror
    /// its new-text-file behavior without spawning one Git process per path.
    nonisolated static func untrackedLineAdditions(
        for entries: [Entry], in root: String
    ) -> Int {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        return entries.lazy
            .filter { $0.staged == "?" }
            .reduce(into: 0) { total, entry in
                let fileURL = rootURL.appendingPathComponent(entry.path).standardizedFileURL
                guard fileURL.path.hasPrefix(rootPrefix) else { return }
                total += textLineCount(at: fileURL)
            }
    }

    /// Counts logical lines while using Git's usual NUL-byte binary heuristic.
    /// Symlink content is its destination path, which is one added line.
    private nonisolated static func textLineCount(at url: URL) -> Int {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return 0 }
        if values.isSymbolicLink == true { return 1 }
        guard values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        let binaryProbeSize = 8_000
        guard let probe = try? handle.read(upToCount: binaryProbeSize),
              !probe.contains(0) else { return 0 }

        var byteCount = probe.count
        var newlineCount = probe.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        var lastByte = probe.last

        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        guard byteCount > 0 else { return 0 }
        return newlineCount + (lastByte == 0x0A ? 0 : 1)
    }

    private static func fileDecoration(for entry: Entry) -> FileDecoration {
        let statuses = [entry.staged, entry.unstaged]
        if entry.isConflict || statuses.contains("U") { return .conflict }
        if statuses.contains("?") { return .untracked }
        if entry.staged == "A" { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("R") { return .renamed }
        if statuses.contains("C") { return .copied }
        return .modified
    }

    nonisolated static func parseRecentCommits(_ output: String) -> [RecentCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let clean = record.trimmingCharacters(in: .newlines)
            let fields = clean.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 5, let timestamp = TimeInterval(fields[4]) else {
                return nil
            }
            return RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                date: Date(timeIntervalSince1970: timestamp)
            )
        }
    }

    nonisolated static func detectRepositoryOperation(gitDirectory: GitDirectory) -> String? {
        // Asked for in one go: on a remote repository each name would otherwise
        // be its own round trip, on every refresh, to answer a question that is
        // "no" almost always.
        let present = GitCommand.existingNames(
            [
                "rebase-merge", "rebase-apply", "MERGE_HEAD",
                "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
            ],
            in: gitDirectory
        )
        func exists(_ name: String) -> Bool { present.contains(name) }

        if exists("rebase-merge") || exists("rebase-apply") {
            return String(localized: "Rebase in progress", bundle: .module)
        }
        if exists("MERGE_HEAD") {
            return String(localized: "Merge in progress", bundle: .module)
        }
        if exists("CHERRY_PICK_HEAD") {
            return String(localized: "Cherry-pick in progress", bundle: .module)
        }
        if exists("REVERT_HEAD") {
            return String(localized: "Revert in progress", bundle: .module)
        }
        if exists("BISECT_LOG") {
            return String(localized: "Bisect in progress", bundle: .module)
        }
        return nil
    }
}
