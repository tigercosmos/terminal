//
//  GitCompareModel.swift
//  TerminalCore
//

import Combine
import Dispatch
import Foundation

/// Compares the working tree against a branch or commit the user picks, rather
/// than against HEAD and the index the way the Git panel does.
///
/// The question this answers is "how does my tree differ from `origin/main`, or
/// from that commit last Tuesday?" — so every comparison runs target → working
/// tree. Never target → index: the files stay live and editable, and what the
/// user sees on the right of a compare diff is what is on disk right now.
@MainActor
public final class GitCompareModel: nonisolated ObservableObject {
    /// What the working tree is being compared against.
    nonisolated public struct Target: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A branch, local or remote-tracking. Re-resolved to its tip on
            /// every refresh, so the comparison follows the branch as it moves.
            case branch
            /// Any other revision — a commit, a tag, `HEAD~2`. Pinned to the
            /// commit it resolved to when it was chosen, so the comparison
            /// stays reproducible even as refs move underneath it.
            case revision
        }

        let kind: Kind
        /// What the user picked, and what the UI shows.
        public let name: String
        /// The commit the comparison currently reads from.
        public var oid: String

        public var shortOID: String { String(oid.prefix(7)) }
        public var tracksTip: Bool { kind == .branch }

        /// Header label: a branch stands on its own, while a revision carries
        /// the commit it resolved to — `HEAD~2` means nothing a day later.
        public var displayName: String {
            guard !tracksTip, name != oid, !oid.hasPrefix(name) else { return name }
            return "\(name) (\(shortOID))"
        }
    }

    /// What a file looked like on disk at a moment in time, so a destructive
    /// action can refuse to run against something that has changed since the
    /// user confirmed it. Terminal's premise is that an agent may be writing in
    /// the same tree while a confirmation sheet is open.
    nonisolated public struct FileFingerprint: Equatable, Sendable {
        let exists: Bool
        let size: UInt64
        let modified: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?

        static func of(_ absolutePath: String) -> FileFingerprint {
            let fm = FileManager.default
            let link = try? fm.destinationOfSymbolicLink(atPath: absolutePath)
            guard let attributes = try? fm.attributesOfItem(atPath: absolutePath) else {
                return FileFingerprint(
                    exists: false, size: 0, modified: nil,
                    fileNumber: nil, symbolicLinkDestination: link
                )
            }
            return FileFingerprint(
                exists: true,
                size: (attributes[.size] as? UInt64) ?? 0,
                modified: attributes[.modificationDate] as? Date,
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                symbolicLinkDestination: link
            )
        }
    }

    /// One file that differs between the target and the working tree.
    nonisolated public struct Entry: Identifiable, Equatable, Sendable {
        public var id: String { path }
        /// Repo-relative, as `git diff --name-status -z` reports it.
        public let path: String
        /// `A`/`M`/`D`/`R`/`C`/`T` from name-status, or `?` for a file that
        /// exists only in the working tree.
        public let status: Character
        /// The file's path *at the target* when this row is a rename or a copy.
        public var origPath: String?
        /// Canonical repo that produced this snapshot, so a revert can reject a
        /// stale row after the panel moves to another repository.
        public var repositoryRoot = ""

        public var fileName: String { (path as NSString).lastPathComponent }
        public var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }

        /// Absent from the target's tree, so reverting means removing it.
        public var isAddition: Bool { status == "A" || status == "?" }
        public var isDeletion: Bool { status == "D" }
        /// Only a true rename carries the old path forward on revert. A copy's
        /// old path is an unrelated file that may hold edits the user never
        /// asked to discard, so it is deliberately excluded.
        var isRename: Bool { status == "R" }
        public var isUntracked: Bool { status == "?" }
    }

    @Published public private(set) var rootPath = ""
    /// Where the panel has been pointed, and on which machine.
    @Published public private(set) var panelRoot = PanelRoot.local("")
    /// Stable canonical repository root, used to key the remembered target.
    @Published public private(set) var repositoryIdentity = ""
    @Published public private(set) var isRepo = false
    @Published public private(set) var branch: String?
    @Published public private(set) var target: Target?
    @Published public private(set) var entries: [Entry] = []
    /// Local branches first, then remote-tracking ones, for the target picker.
    @Published public private(set) var localBranches: [String] = []
    @Published public private(set) var remoteBranches: [String] = []
    @Published public private(set) var recentCommits: [GitStatusModel.RecentCommit] = []
    @Published public private(set) var isRefreshing = false
    /// True once a comparison has resolved for the current target, so later
    /// event-driven refreshes keep showing the list instead of flashing a
    /// loading placeholder.
    @Published public private(set) var hasResolvedList = false
    @Published public private(set) var statusError: String?
    /// Set when the chosen target no longer resolves — a deleted branch, a
    /// commit that a rewrite dropped. The target is kept so the message can
    /// name it and the user can retry after a fetch.
    @Published public private(set) var targetError: String?
    /// True while a revert runs.
    @Published public private(set) var isBusy = false
    @Published public var lastError: String?

    public init() {}
    /// Paths whose working-tree contents match the active content search, or
    /// nil when no search is running. Only the changed set is read, so the
    /// search stays bounded by the comparison rather than by the repository.
    @Published public private(set) var searchMatches: Set<String>?
    /// Why a regex query would not compile, shown under the search field.
    @Published public private(set) var searchError: String?
    @Published public private(set) var isSearching = false

    /// Absolute repository root; every path in `entries` is relative to it.
    private var topLevel = ""
    /// The chosen target per repository, so switching projects and coming back
    /// resumes the same comparison instead of dropping it.
    private var targetsByRepository: [String: Target] = [:]
    /// Invalidates async work after the panel moves to another directory.
    private var contextGeneration: UInt = 0
    /// Invalidates an in-flight load when a revert begins, so a pre-operation
    /// snapshot cannot overwrite the post-operation state.
    private var loadRequestID: UInt = 0
    /// Coalesces an event that arrives while a load or a revert is running.
    private var refreshPending = false
    /// When the last comparison finished, for the remote polling interval.
    private var lastLoad: Date?
    private var runningOperationID: UUID?
    /// Invalidates a search whose inputs or file set have moved on.
    private var searchRequestID: UInt = 0
    private var activeSearch: CompareFilter?

    public var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    /// The ssh connection the repository sits behind, when the terminal has
    /// followed one onto another machine. Nil for a repository on this Mac.
    public var remote: RemoteShellDestination? { panelRoot.remote }

    /// True when the comparison is looking wherever an ssh command lands
    /// because the remote shell has never said where it is.
    public var isSearchingRemoteLoginDirectory: Bool {
        panelRoot.isRemoteLoginFallback && !isRepo
    }

    /// The repository, and the machine it is on.
    public var repoDirectory: GitDirectory {
        GitDirectory(repoRoot, on: remote)
    }

    /// The directory the panel was pointed at, before Git resolved which
    /// repository contains it.
    var rootDirectory: GitDirectory {
        GitDirectory(rootPath, on: remote)
    }

    /// The host whose repository is compared, when it is not this machine's.
    public var remoteHost: String? { remote?.host }

    /// Whether a revert can run. A remote comparison is read-only for the same
    /// reason the remote file tree is: reverting a working-tree addition means
    /// moving it to the Trash, which is a thing on this Mac.
    public var isEditable: Bool { remote == nil }

    /// What the panel calls the directory it is describing, host-qualified when
    /// the repository is on another machine.
    public var displayPath: String {
        GitDirectory(isRepo ? repoRoot : rootPath, on: remote).displayPath
    }

    /// Host-qualified key for the remembered target: the same path names a
    /// different repository on a different machine.
    private var targetKey: String {
        repoDirectory.displayPath
    }

    public var hasTarget: Bool { target != nil }

    /// True while the first comparison for the current target is still in
    /// flight.
    public var isResolvingInitialList: Bool {
        isRefreshing && !hasResolvedList
    }

    public func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    public func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    // MARK: - Lifecycle

    /// Points the panel at `root`, on this Mac or on the host a terminal has
    /// ssh'd into. `polling` marks a tick from the panel's timer rather than
    /// something the user did; see ``refreshIfStale()``.
    public func sync(root: PanelRoot, polling: Bool = false) {
        var moved = false
        if root != panelRoot {
            let sameMachine = root.remote == panelRoot.remote
            contextGeneration &+= 1
            panelRoot = root
            rootPath = root.provisionalPath
            hasResolvedList = false
            clearRepositoryState(preserveIdentity: sameMachine)
            moved = true
        }
        if polling && !moved {
            refreshIfStale()
        } else {
            refresh()
        }
    }

    /// How long a remote comparison is trusted before the panel's next tick
    /// re-runs it. Matches the Git panel's interval, since the two answer the
    /// same question about the same connection.
    private static let remoteRefreshInterval: TimeInterval = 5

    /// A tick from the panel's timer. Only a repository on another machine is
    /// polled: a terminal sitting inside `ssh` finishes no commands, so the
    /// completion events a local comparison refreshes on never arrive.
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
        loadRequestID &+= 1
        let requestID = loadRequestID
        isRefreshing = true
        let requested = target

        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> (GitDirectory, LoadResult) in
                // See `GitStatusModel.refresh()`: placing a remote root means
                // asking the host, so it happens here rather than on the way in.
                let directory = root.directory()
                return (directory, Self.load(root: directory, target: requested))
            }.value
            guard let self, self.contextGeneration == generation,
                  self.loadRequestID == requestID,
                  self.panelRoot == root else { return }
            self.isRefreshing = false
            self.lastLoad = Date()
            self.rootPath = loaded.0.path
            self.apply(loaded.1)
            self.hasResolvedList = true
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    // MARK: - Target selection

    /// Points the comparison at `revision`. A branch name keeps tip-tracking
    /// semantics; anything else — a tag, a SHA, `HEAD~2` — is pinned to the
    /// commit it resolves to right now.
    public func setTarget(_ revision: String, kind: Target.Kind) {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.isSafeRef(trimmed) else {
            lastError = String(localized: "A revision cannot begin with “-”.", bundle: .module)
            return
        }
        guard isRepo else {
            lastError = String(localized: "Open a Git repository first", bundle: .module)
            return
        }
        let root = repoDirectory
        let key = targetKey
        let generation = contextGeneration
        loadRequestID &+= 1
        // Choosing A then B must land on B even when A resolves last, and
        // clearing the target while one is in flight must stick.
        let requestID = loadRequestID
        isRefreshing = true

        Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveCommit(trimmed, in: root)
            }.value
            guard let self, self.contextGeneration == generation,
                  self.loadRequestID == requestID else { return }
            self.isRefreshing = false
            guard let resolved else {
                self.lastError = String(
                    localized: "“\(trimmed)” is not a revision in this repository.", bundle: .module,
                    comment: "Error shown when a typed comparison target does not resolve."
                )
                return
            }
            self.lastError = nil
            self.targetError = nil
            self.hasResolvedList = false
            self.entries = []
            let target = Target(kind: kind, name: trimmed, oid: resolved)
            self.target = target
            self.targetsByRepository[key] = target
            self.refresh()
        }
    }

    /// Drops the comparison. The panel goes back to asking for a target.
    public func clearTarget() {
        // Invalidates an in-flight `setTarget`, which would otherwise land
        // after this and quietly bring the comparison back.
        loadRequestID &+= 1
        target = nil
        targetError = nil
        entries = []
        hasResolvedList = false
        if !repoRoot.isEmpty {
            targetsByRepository[targetKey] = nil
        }
    }

    // MARK: - Revert

    /// Restores one file to its state at the target: content is checked out for
    /// a path that exists there, and a path that does not exist there is
    /// dropped from the index and moved to the Trash. The UI confirms first.
    /// The file as it was when the confirmation was raised. `revert` refuses to
    /// run if it no longer matches.
    public func fingerprint(for entry: Entry) -> FileFingerprint {
        .of(absolutePath(for: entry))
    }

    public func revert(_ entry: Entry, confirmedAs confirmed: FileFingerprint? = nil) {
        guard let target else { return }
        // Checked here rather than trusting the panel to have hidden the
        // action: a revert writes, and the panel can be showing a repository on
        // another machine one refresh after it was showing a local one.
        guard isEditable else {
            failImmediately(
                String(localized: "This repository is on \(remoteHost ?? ""), which Terminal compares but does not change.", bundle: .module)
            )
            return
        }
        guard isCurrent(entry) else {
            failImmediately(
                String(localized: "Repository changed; refresh and try the revert again", bundle: .module)
            )
            return
        }
        guard !isBusy else { return }

        let root = repoDirectory
        let oid = target.oid
        let generation = contextGeneration
        // Only a true rename restores its old path; see `Entry.isRename`.
        let renameFrom = entry.isRename ? entry.origPath : nil
        let path = entry.path
        let absolutePath = absolutePath(for: entry)
        let label = String(localized: "Revert \(entry.fileName)", bundle: .module)
        let operationID = UUID()
        invalidateLoad()
        runningOperationID = operationID
        isBusy = true
        lastError = nil

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard Self.resolveRepositoryRoot(in: root) == root.path else {
                    return String(localized: "Repository changed before the revert could run. Review the current changes and try again.", bundle: .module)
                }
                // The pinned commit must still be there: a rewrite or a prune
                // between listing and reverting would otherwise check out
                // nothing and leave the file untouched while reporting success.
                guard Self.resolveCommit(oid, in: root) == oid else {
                    return String(localized: "The comparison target is no longer in this repository. Refresh and try again.", bundle: .module)
                }
                // Checked here rather than at the confirmation, so a write that
                // lands while the sheet is up cannot be discarded unseen.
                if let confirmed, FileFingerprint.of(absolutePath) != confirmed {
                    return String(localized: "\(path) changed while the confirmation was open, so nothing was reverted. Review it and try again.", bundle: .module)
                }
                return Self.revertToTarget(
                    path: path, renameFrom: renameFrom, oid: oid, in: root
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation else {
                self.refresh()
                return
            }
            self.lastError = failure
            self.refresh()
        }
    }

    private func failImmediately(_ message: String) {
        guard !isBusy else { return }
        lastError = message
    }

    private func invalidateLoad() {
        loadRequestID &+= 1
        isRefreshing = false
        refreshPending = false
    }

    // MARK: - Applying a load

    private func clearRepositoryState(preserveIdentity: Bool = false) {
        topLevel = ""
        isRepo = false
        branch = nil
        target = nil
        targetError = nil
        entries = []
        localBranches = []
        remoteBranches = []
        recentCommits = []
        isRefreshing = false
        isBusy = runningOperationID != nil
        statusError = nil
        loadRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ result: LoadResult) {
        switch result {
        case .notRepository:
            if isBusy { return }
            clearRepositoryState()
        case .failed(let message):
            if isBusy { return }
            clearRepositoryState(preserveIdentity: true)
            statusError = message
        case .repository(let loaded):
            statusError = nil
            applyRepository(loaded)
        }
    }

    private func applyRepository(_ loaded: Loaded) {
        isRepo = true
        branch = loaded.branch
        topLevel = loaded.topLevel
        repositoryIdentity = GitDirectory(loaded.topLevel, on: remote).displayPath
        localBranches = loaded.localBranches
        remoteBranches = loaded.remoteBranches
        recentCommits = loaded.recentCommits

        // Entering a repository for the first time picks up whatever target was
        // last used there, so the comparison survives switching projects.
        if target == nil, let remembered = targetsByRepository[targetKey] {
            target = remembered
        }
        guard target != nil else {
            entries = []
            targetError = nil
            return
        }
        if let resolved = loaded.resolvedOID {
            targetError = nil
            target?.oid = resolved
            if let target { targetsByRepository[targetKey] = target }
            let refreshed = loaded.entries.map { entry -> Entry in
                var entry = entry
                entry.repositoryRoot = loaded.topLevel
                return entry
            }
            // Compares the entries themselves, not just their paths: a file
            // can keep its path while its contents start or stop matching the
            // query, and a status change (modified → deleted) changes what
            // there is to search at all.
            let changedSet = refreshed != entries
            entries = refreshed
            if changedSet, let activeSearch { runSearch(activeSearch) }
        } else {
            // Keep the target so the message can name it and a fetch can bring
            // it back; drop the list, which no longer describes anything.
            targetError = String(
                localized: "“\(target?.name ?? "")” is no longer in this repository.", bundle: .module,
                comment: "Shown when a chosen comparison target stops resolving."
            )
            entries = []
        }
    }

    // MARK: - Content search

    /// Runs `filter`'s query across the working-tree contents of the changed
    /// files. A filter with no query clears any previous result rather than
    /// leaving a stale one narrowing the list.
    public func applySearch(_ filter: CompareFilter) {
        guard filter.hasQuery else {
            activeSearch = nil
            searchRequestID &+= 1
            isSearching = false
            searchMatches = nil
            searchError = nil
            return
        }
        activeSearch = filter
        runSearch(filter)
    }

    private func runSearch(_ filter: CompareFilter) {
        switch CompareFilterCompiler.search(filter) {
        case .none:
            searchMatches = nil
            searchError = nil
            return
        case .invalid(let message):
            // Leave the previous matches in place: a half-typed regex should
            // not empty the list on its way to a valid one.
            searchError = message
            return
        case .matcher(let expression):
            searchError = nil
            searchRequestID &+= 1
            let requestID = searchRequestID
            let generation = contextGeneration
            let root = repoDirectory
            let paths = entries.map(\.path)
            isSearching = true

            Task { [weak self] in
                let matches = await Task.detached(priority: .userInitiated) {
                    Self.pathsMatching(expression, paths: paths, in: root)
                }.value
                guard let self, self.contextGeneration == generation,
                      self.searchRequestID == requestID else { return }
                self.isSearching = false
                self.searchMatches = matches
            }
        }
    }

    private nonisolated static func pathsMatching(
        _ expression: NSRegularExpression, paths: [String], in root: GitDirectory
    ) -> Set<String> {
        var matches: Set<String> = []
        for path in paths {
            // A path whose name matches counts even when its contents cannot be
            // read — a deleted file has no contents left to search.
            let range = NSRange(path.startIndex..., in: path)
            if expression.firstMatch(in: path, options: [], range: range) != nil {
                matches.insert(path)
                continue
            }
            var failure: String?
            let contents = GitFileContent.worktreeFile(
                root: root, path: path, error: &failure
            )
            guard failure == nil, !contents.isEmpty else { continue }
            let contentRange = NSRange(contents.startIndex..., in: contents)
            if expression.firstMatch(in: contents, options: [], range: contentRange) != nil {
                matches.insert(path)
            }
        }
        return matches
    }

    // MARK: - Loading

    private nonisolated enum LoadFailure: Error {
        case message(String)
    }

    private nonisolated enum LoadResult: Sendable {
        case repository(Loaded)
        case notRepository
        case failed(String)
    }

    private nonisolated struct Loaded: Sendable {
        var topLevel = ""
        public var branch: String?
        public var localBranches: [String] = []
        public var remoteBranches: [String] = []
        public var recentCommits: [GitStatusModel.RecentCommit] = []
        /// Where the target resolved this time round — a branch's current tip,
        /// or the pinned commit re-verified. Nil when it no longer resolves.
        var resolvedOID: String?
        public var entries: [Entry] = []
    }

    private nonisolated static func load(root: GitDirectory, target: Target?) -> LoadResult {
        let top = GitCommand.run(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let message = [top.stderr, top.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? String(localized: "Unable to locate the Git repository.", bundle: .module)
            if top.status == 128, message.localizedCaseInsensitiveContains("not a git repository") {
                return .notRepository
            }
            return .failed(message)
        }
        let resolvedRoot = trimmedLine(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path.", bundle: .module))
        }
        let repoRoot = root.directory(resolvedRoot)

        var loaded = Loaded()
        loaded.topLevel = resolvedRoot

        // Fails on a detached HEAD, which simply has no branch to name.
        let head = GitCommand.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repoRoot)
        loaded.branch = head.status == 0 ? trimmedLine(head.stdout) : nil

        let locals = GitCommand.run(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repoRoot
        )
        if locals.status == 0 {
            loaded.localBranches = locals.stdout.split(separator: "\n").map(String.init).sorted()
        }
        let remotes = GitCommand.run(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: repoRoot
        )
        if remotes.status == 0 {
            // `origin/HEAD` is a symbolic pointer at another entry in this same
            // list, so offering it as a target would just duplicate a branch.
            loaded.remoteBranches = remotes.stdout
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasSuffix("/HEAD") }
                .sorted()
        }

        let log = GitCommand.run(
            ["log", "-n", "20", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"],
            in: repoRoot
        )
        if log.status == 0 {
            loaded.recentCommits = GitStatusModel.parseRecentCommits(log.stdout)
        }

        guard let target else { return .repository(loaded) }
        // A branch follows its tip; everything else is re-verified where it was
        // pinned, which also catches a commit dropped by a rewrite.
        let resolved = resolveCommit(target.tracksTip ? target.name : target.oid, in: repoRoot)
        guard let resolved else { return .repository(loaded) }
        loaded.resolvedOID = resolved
        do {
            loaded.entries = try changedPaths(against: resolved, in: repoRoot)
        } catch let LoadFailure.message(message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .repository(loaded)
    }

    /// Every file that differs between `oid` and the working tree — tracked
    /// differences from `git diff`, plus files that exist only in the tree.
    ///
    /// Throws rather than returning an empty list on failure: "Git could not
    /// answer" and "nothing differs" look identical in a list, and the second
    /// is a claim this must never make on the first's behalf.
    private nonisolated static func changedPaths(
        against oid: String, in root: GitDirectory
    ) throws -> [Entry] {
        let diff = GitCommand.run(
            ["diff", "--name-status", "-z", "--end-of-options", oid], in: root
        )
        guard diff.status == 0 else {
            throw LoadFailure.message(
                failure(diff, path: String(localized: "the comparison", bundle: .module))
            )
        }
        var entries = parseNameStatus(diff.stdout)

        let untracked = GitCommand.run(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: root
        )
        guard untracked.status == 0 else {
            throw LoadFailure.message(
                failure(untracked, path: String(localized: "the untracked files", bundle: .module))
            )
        }
        if untracked.status == 0 {
            // A path can reach both lists — `git rm --cached` leaves the file on
            // disk while Git still reports it as deleted. The diff row is the
            // one that describes the comparison, so it wins and the duplicate is
            // dropped; two rows sharing a path would also collide as list ids.
            var seen = Set(entries.map(\.path))
            for path in untracked.stdout.split(separator: "\0").map(String.init)
            where !path.isEmpty && !seen.contains(path) {
                seen.insert(path)
                entries.append(Entry(path: path, status: "?"))
            }
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Parses NUL-delimited `--name-status`. Unlike Git's default quoted
    /// output this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseNameStatus(_ output: String) -> [Entry] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [Entry] = []
        var index = 0
        while index < fields.count {
            guard let status = fields[index].first else {
                index += 1
                continue
            }
            // Renames and copies carry a similarity score and two paths; every
            // other status is one letter followed by a single path.
            if status == "R" || status == "C" {
                guard index + 2 < fields.count else { break }
                entries.append(
                    Entry(
                        path: fields[index + 2], status: status,
                        origPath: fields[index + 1]
                    )
                )
                index += 3
            } else {
                guard index + 1 < fields.count else { break }
                entries.append(Entry(path: fields[index + 1], status: status))
                index += 2
            }
        }
        return entries
    }

    // MARK: - Git plumbing

    /// Refs must never reach Git as options. `--end-of-options` covers the
    /// commands that accept it, but `git checkout <ref> -- <path>` misparses it
    /// as a second ref ("only one reference expected, 2 given") — so rejecting
    /// a leading dash up front is what actually protects every call site.
    nonisolated static func isSafeRef(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("-")
    }

    /// The commit `ref` names, or nil when it is not a revision in this
    /// repository. `^{commit}` also rejects a tag that points at a blob.
    nonisolated static func resolveCommit(_ ref: String, in root: GitDirectory) -> String? {
        guard isSafeRef(ref) else { return nil }
        let run = GitCommand.run(
            ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], in: root
        )
        guard run.status == 0 else { return nil }
        let oid = trimmedLine(run.stdout)
        // SHA-1 is 40 characters and SHA-256 is 64; both are pure hex.
        guard oid.count >= 40, oid.allSatisfy(\.isHexDigit) else { return nil }
        return oid
    }

    private nonisolated static func resolveRepositoryRoot(in root: GitDirectory) -> String? {
        let top = GitCommand.run(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else { return nil }
        let path = trimmedLine(top.stdout)
        return path.isEmpty ? nil : path
    }

    /// Whether `path` is in the tree at `oid` — or whether Git could not say.
    ///
    /// The three states matter because the answer picks between restoring a
    /// file and deleting it. Collapsing a failed probe into "absent" would let
    /// a transient Git error move a file the target really has to the Trash.
    private nonisolated enum TreeMembership {
        case present
        case absent
        case unknown(String)
    }

    /// The pathspec carries `:(literal)` so a name holding `*`, `?`, or `[…]`
    /// matches verbatim — keeping this check in lock-step with the literal
    /// pathspec the checkout below uses. `git checkout` does glob its pathspec
    /// while `ls-tree` matches more literally, so without this the gate and the
    /// destructive action it guards could disagree about which files are meant.
    private nonisolated static func membership(
        ofPath path: String, atCommit oid: String, in root: GitDirectory
    ) -> TreeMembership {
        let run = GitCommand.run(
            ["ls-tree", "--name-only", "-z", "--end-of-options", oid, "--", ":(literal)\(path)"],
            in: root
        )
        guard run.status == 0 else {
            return .unknown(failure(run, path: path))
        }
        return run.stdout.split(separator: "\0").map(String.init).contains(path)
            ? .present
            : .absent
    }

    /// Restores one path to its state at `oid`. Returns a message on failure.
    private nonisolated static func revertToTarget(
        path: String, renameFrom: String?, oid: String, in root: GitDirectory
    ) -> String? {
        // `--` ends options but does NOT disable glob interpretation, so a path
        // holding `*`, `?`, or `[…]` would otherwise match — and destructively
        // revert — sibling files. `:(literal)` forces the whole string to be
        // read as one path.
        let literal = ":(literal)\(path)"

        if let renameFrom, renameFrom != path {
            // Restore the old name first, so a failure aborts before anything is
            // removed and the tree is left exactly as it was.
            let restore = GitCommand.run(
                ["checkout", oid, "--", ":(literal)\(renameFrom)"], in: root
            )
            guard restore.status == 0 else { return failure(restore, path: renameFrom) }
            // Index-only: drop the stale new-path entry. Never touches disk.
            let unstage = GitCommand.run(
                ["rm", "-f", "--cached", "--ignore-unmatch", "--", literal], in: root
            )
            guard unstage.status == 0 else { return failure(unstage, path: path) }
            // A case-only rename (`Foo.swift` → `foo.swift`) on a
            // case-insensitive volume — the macOS default — leaves both names
            // pointing at one inode, so removing the new path here would wipe
            // the file the checkout just restored.
            guard !isSameFileSystemEntry(
                root.appending(path), root.appending(renameFrom)
            ) else { return nil }
            return trash(path: path, in: root)
        }

        switch membership(ofPath: path, atCommit: oid, in: root) {
        case .present:
            // No `--end-of-options` here: checkout reads it as a second ref.
            // `isSafeRef` on the way in is what protects the ref itself.
            let run = GitCommand.run(["checkout", oid, "--", literal], in: root)
            return run.status == 0 ? nil : failure(run, path: path)
        case .unknown(let message):
            // Never guess. Guessing "absent" here deletes the file.
            return String(
                localized: "Could not tell whether \(path) exists at the comparison target, so nothing was changed: \(message)", bundle: .module,
                comment: "Revert aborted because Git could not read the target's tree."
            )
        case .absent:
            break
        }

        // Absent at the target, so this is a working-tree addition.
        // `--ignore-unmatch` keeps `rm` at exit 0 when the path was never
        // staged; a real failure (an index lock, a rejected pathspec) still
        // aborts before anything leaves the working tree.
        let unstage = GitCommand.run(
            ["rm", "-f", "--cached", "--ignore-unmatch", "--", literal], in: root
        )
        guard unstage.status == 0 else { return failure(unstage, path: path) }
        return trash(path: path, in: root)
    }

    /// Removes a path the target does not have. The Trash rather than an
    /// unlink, matching how the Git panel discards untracked files: reverting
    /// to a target is undoable in Git only for content Git already knows about.
    private nonisolated static func trash(path: String, in root: GitDirectory) -> String? {
        let url = URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private nonisolated static func isSameFileSystemEntry(_ lhs: String, _ rhs: String) -> Bool {
        let fm = FileManager.default
        guard let left = try? fm.attributesOfItem(atPath: lhs),
              let right = try? fm.attributesOfItem(atPath: rhs),
              let leftNode = left[.systemFileNumber] as? Int,
              let rightNode = right[.systemFileNumber] as? Int,
              let leftDevice = left[.systemNumber] as? Int,
              let rightDevice = right[.systemNumber] as? Int
        else { return false }
        return leftNode == rightNode && leftDevice == rightDevice
    }

    /// Git's own diagnostic, made safe to show; see
    /// ``GitStatusModel.gitFailureMessage(_:fallback:)`` for why the cleaning
    /// happens here rather than on the way out of the command.
    private nonisolated static func failure(
        _ run: (status: Int32, stdout: String, stderr: String), path: String
    ) -> String {
        let text = [run.stderr, run.stdout]
            .lazy
            .map { RemoteFileService.sanitized($0, maxLines: 8) }
            .first { !$0.isEmpty }
        return text ?? String(localized: "Unable to revert \(path)", bundle: .module)
    }

    private nonisolated static func trimmedLine(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
