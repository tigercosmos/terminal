//
//  GitCompareModel.swift
//  terminal
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
final class GitCompareModel: nonisolated ObservableObject {
    /// What the working tree is being compared against.
    nonisolated struct Target: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
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
        let name: String
        /// The commit the comparison currently reads from.
        var oid: String

        var shortOID: String { String(oid.prefix(7)) }
        var tracksTip: Bool { kind == .branch }

        /// Header label: a branch stands on its own, while a revision carries
        /// the commit it resolved to — `HEAD~2` means nothing a day later.
        var displayName: String {
            guard !tracksTip, name != oid, !oid.hasPrefix(name) else { return name }
            return "\(name) (\(shortOID))"
        }
    }

    /// What a file looked like on disk at a moment in time, so a destructive
    /// action can refuse to run against something that has changed since the
    /// user confirmed it. Terminal's premise is that an agent may be writing in
    /// the same tree while a confirmation sheet is open.
    nonisolated struct FileFingerprint: Equatable, Sendable {
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
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Repo-relative, as `git diff --name-status -z` reports it.
        let path: String
        /// `A`/`M`/`D`/`R`/`C`/`T` from name-status, or `?` for a file that
        /// exists only in the working tree.
        let status: Character
        /// The file's path *at the target* when this row is a rename or a copy.
        var origPath: String?
        /// Canonical repo that produced this snapshot, so a revert can reject a
        /// stale row after the panel moves to another repository.
        var repositoryRoot = ""

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }

        /// Absent from the target's tree, so reverting means removing it.
        var isAddition: Bool { status == "A" || status == "?" }
        var isDeletion: Bool { status == "D" }
        /// Only a true rename carries the old path forward on revert. A copy's
        /// old path is an unrelated file that may hold edits the user never
        /// asked to discard, so it is deliberately excluded.
        var isRename: Bool { status == "R" }
        var isUntracked: Bool { status == "?" }
    }

    @Published private(set) var rootPath = ""
    /// Stable canonical repository root, used to key the remembered target.
    @Published private(set) var repositoryIdentity = ""
    @Published private(set) var isRepo = false
    @Published private(set) var branch: String?
    @Published private(set) var target: Target?
    @Published private(set) var entries: [Entry] = []
    /// Local branches first, then remote-tracking ones, for the target picker.
    @Published private(set) var localBranches: [String] = []
    @Published private(set) var remoteBranches: [String] = []
    @Published private(set) var recentCommits: [GitStatusModel.RecentCommit] = []
    @Published private(set) var isRefreshing = false
    /// True once a comparison has resolved for the current target, so later
    /// event-driven refreshes keep showing the list instead of flashing a
    /// loading placeholder.
    @Published private(set) var hasResolvedList = false
    @Published private(set) var statusError: String?
    /// Set when the chosen target no longer resolves — a deleted branch, a
    /// commit that a rewrite dropped. The target is kept so the message can
    /// name it and the user can retry after a fetch.
    @Published private(set) var targetError: String?
    /// True while a revert runs.
    @Published private(set) var isBusy = false
    @Published var lastError: String?
    /// Paths whose working-tree contents match the active content search, or
    /// nil when no search is running. Only the changed set is read, so the
    /// search stays bounded by the comparison rather than by the repository.
    @Published private(set) var searchMatches: Set<String>?
    /// Why a regex query would not compile, shown under the search field.
    @Published private(set) var searchError: String?
    @Published private(set) var isSearching = false

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
    private var runningOperationID: UUID?
    /// Invalidates a search whose inputs or file set have moved on.
    private var searchRequestID: UInt = 0
    private var activeSearch: CompareFilter?

    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    var hasTarget: Bool { target != nil }

    /// True while the first comparison for the current target is still in
    /// flight.
    var isResolvingInitialList: Bool {
        isRefreshing && !hasResolvedList
    }

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    // MARK: - Lifecycle

    func sync(root: String) {
        if root != rootPath {
            contextGeneration &+= 1
            rootPath = root
            hasResolvedList = false
            clearRepositoryState(preserveIdentity: true)
        }
        refresh()
    }

    func refresh() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty else { return }
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
            let result = await Task.detached(priority: .utility) {
                Self.load(root: root, target: requested)
            }.value
            guard let self, self.contextGeneration == generation,
                  self.loadRequestID == requestID,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            self.apply(result)
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
    func setTarget(_ revision: String, kind: Target.Kind) {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.isSafeRef(trimmed) else {
            lastError = String(localized: "A revision cannot begin with “-”.")
            return
        }
        guard isRepo else {
            lastError = String(localized: "Open a Git repository first")
            return
        }
        let root = repoRoot
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
                    localized: "“\(trimmed)” is not a revision in this repository.",
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
            self.targetsByRepository[root] = target
            self.refresh()
        }
    }

    /// Drops the comparison. The panel goes back to asking for a target.
    func clearTarget() {
        // Invalidates an in-flight `setTarget`, which would otherwise land
        // after this and quietly bring the comparison back.
        loadRequestID &+= 1
        target = nil
        targetError = nil
        entries = []
        hasResolvedList = false
        if !repoRoot.isEmpty {
            targetsByRepository[repoRoot] = nil
        }
    }

    // MARK: - Revert

    /// Restores one file to its state at the target: content is checked out for
    /// a path that exists there, and a path that does not exist there is
    /// dropped from the index and moved to the Trash. The UI confirms first.
    /// The file as it was when the confirmation was raised. `revert` refuses to
    /// run if it no longer matches.
    func fingerprint(for entry: Entry) -> FileFingerprint {
        .of(absolutePath(for: entry))
    }

    func revert(_ entry: Entry, confirmedAs confirmed: FileFingerprint? = nil) {
        guard let target else { return }
        guard isCurrent(entry) else {
            failImmediately(
                String(localized: "Repository changed; refresh and try the revert again")
            )
            return
        }
        guard !isBusy else { return }

        let root = repoRoot
        let oid = target.oid
        let generation = contextGeneration
        // Only a true rename restores its old path; see `Entry.isRename`.
        let renameFrom = entry.isRename ? entry.origPath : nil
        let path = entry.path
        let absolutePath = absolutePath(for: entry)
        let label = String(localized: "Revert \(entry.fileName)")
        let operationID = UUID()
        invalidateLoad()
        runningOperationID = operationID
        isBusy = true
        lastError = nil

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard Self.resolveRepositoryRoot(in: root) == root else {
                    return String(localized: "Repository changed before the revert could run. Review the current changes and try again.")
                }
                // The pinned commit must still be there: a rewrite or a prune
                // between listing and reverting would otherwise check out
                // nothing and leave the file untouched while reporting success.
                guard Self.resolveCommit(oid, in: root) == oid else {
                    return String(localized: "The comparison target is no longer in this repository. Refresh and try again.")
                }
                // Checked here rather than at the confirmation, so a write that
                // lands while the sheet is up cannot be discarded unseen.
                if let confirmed, FileFingerprint.of(absolutePath) != confirmed {
                    return String(localized: "\(path) changed while the confirmation was open, so nothing was reverted. Review it and try again.")
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
        repositoryIdentity = loaded.topLevel
        localBranches = loaded.localBranches
        remoteBranches = loaded.remoteBranches
        recentCommits = loaded.recentCommits

        // Entering a repository for the first time picks up whatever target was
        // last used there, so the comparison survives switching projects.
        if target == nil, let remembered = targetsByRepository[loaded.topLevel] {
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
            if let target { targetsByRepository[loaded.topLevel] = target }
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
                localized: "“\(target?.name ?? "")” is no longer in this repository.",
                comment: "Shown when a chosen comparison target stops resolving."
            )
            entries = []
        }
    }

    // MARK: - Content search

    /// Runs `filter`'s query across the working-tree contents of the changed
    /// files. A filter with no query clears any previous result rather than
    /// leaving a stale one narrowing the list.
    func applySearch(_ filter: CompareFilter) {
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
            let root = repoRoot
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
        _ expression: NSRegularExpression, paths: [String], in root: String
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
        var branch: String?
        var localBranches: [String] = []
        var remoteBranches: [String] = []
        var recentCommits: [GitStatusModel.RecentCommit] = []
        /// Where the target resolved this time round — a branch's current tip,
        /// or the pinned commit re-verified. Nil when it no longer resolves.
        var resolvedOID: String?
        var entries: [Entry] = []
    }

    private nonisolated static func load(root: String, target: Target?) -> LoadResult {
        let top = GitStatusModel.runGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let message = [top.stderr, top.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? String(localized: "Unable to locate the Git repository.")
            if top.status == 128, message.localizedCaseInsensitiveContains("not a git repository") {
                return .notRepository
            }
            return .failed(message)
        }
        let repoRoot = trimmedLine(top.stdout)
        guard !repoRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path."))
        }

        var loaded = Loaded()
        loaded.topLevel = repoRoot

        // Fails on a detached HEAD, which simply has no branch to name.
        let head = GitStatusModel.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repoRoot)
        loaded.branch = head.status == 0 ? trimmedLine(head.stdout) : nil

        let locals = GitStatusModel.runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repoRoot
        )
        if locals.status == 0 {
            loaded.localBranches = locals.stdout.split(separator: "\n").map(String.init).sorted()
        }
        let remotes = GitStatusModel.runGit(
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

        let log = GitStatusModel.runGit(
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
        against oid: String, in root: String
    ) throws -> [Entry] {
        let diff = GitStatusModel.runGit(
            ["diff", "--name-status", "-z", "--end-of-options", oid], in: root
        )
        guard diff.status == 0 else {
            throw LoadFailure.message(
                failure(diff, path: String(localized: "the comparison"))
            )
        }
        var entries = parseNameStatus(diff.stdout)

        let untracked = GitStatusModel.runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: root
        )
        guard untracked.status == 0 else {
            throw LoadFailure.message(
                failure(untracked, path: String(localized: "the untracked files"))
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
    nonisolated static func resolveCommit(_ ref: String, in root: String) -> String? {
        guard isSafeRef(ref) else { return nil }
        let run = GitStatusModel.runGit(
            ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], in: root
        )
        guard run.status == 0 else { return nil }
        let oid = trimmedLine(run.stdout)
        // SHA-1 is 40 characters and SHA-256 is 64; both are pure hex.
        guard oid.count >= 40, oid.allSatisfy(\.isHexDigit) else { return nil }
        return oid
    }

    private nonisolated static func resolveRepositoryRoot(in root: String) -> String? {
        let top = GitStatusModel.runGit(["rev-parse", "--show-toplevel"], in: root)
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
        ofPath path: String, atCommit oid: String, in root: String
    ) -> TreeMembership {
        let run = GitStatusModel.runGit(
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
        path: String, renameFrom: String?, oid: String, in root: String
    ) -> String? {
        // `--` ends options but does NOT disable glob interpretation, so a path
        // holding `*`, `?`, or `[…]` would otherwise match — and destructively
        // revert — sibling files. `:(literal)` forces the whole string to be
        // read as one path.
        let literal = ":(literal)\(path)"

        if let renameFrom, renameFrom != path {
            // Restore the old name first, so a failure aborts before anything is
            // removed and the tree is left exactly as it was.
            let restore = GitStatusModel.runGit(
                ["checkout", oid, "--", ":(literal)\(renameFrom)"], in: root
            )
            guard restore.status == 0 else { return failure(restore, path: renameFrom) }
            // Index-only: drop the stale new-path entry. Never touches disk.
            let unstage = GitStatusModel.runGit(
                ["rm", "-f", "--cached", "--ignore-unmatch", "--", literal], in: root
            )
            guard unstage.status == 0 else { return failure(unstage, path: path) }
            // A case-only rename (`Foo.swift` → `foo.swift`) on a
            // case-insensitive volume — the macOS default — leaves both names
            // pointing at one inode, so removing the new path here would wipe
            // the file the checkout just restored.
            guard !isSameFileSystemEntry(
                (root as NSString).appendingPathComponent(path),
                (root as NSString).appendingPathComponent(renameFrom)
            ) else { return nil }
            return trash(path: path, in: root)
        }

        switch membership(ofPath: path, atCommit: oid, in: root) {
        case .present:
            // No `--end-of-options` here: checkout reads it as a second ref.
            // `isSafeRef` on the way in is what protects the ref itself.
            let run = GitStatusModel.runGit(["checkout", oid, "--", literal], in: root)
            return run.status == 0 ? nil : failure(run, path: path)
        case .unknown(let message):
            // Never guess. Guessing "absent" here deletes the file.
            return String(
                localized: "Could not tell whether \(path) exists at the comparison target, so nothing was changed: \(message)",
                comment: "Revert aborted because Git could not read the target's tree."
            )
        case .absent:
            break
        }

        // Absent at the target, so this is a working-tree addition.
        // `--ignore-unmatch` keeps `rm` at exit 0 when the path was never
        // staged; a real failure (an index lock, a rejected pathspec) still
        // aborts before anything leaves the working tree.
        let unstage = GitStatusModel.runGit(
            ["rm", "-f", "--cached", "--ignore-unmatch", "--", literal], in: root
        )
        guard unstage.status == 0 else { return failure(unstage, path: path) }
        return trash(path: path, in: root)
    }

    /// Removes a path the target does not have. The Trash rather than an
    /// unlink, matching how the Git panel discards untracked files: reverting
    /// to a target is undoable in Git only for content Git already knows about.
    private nonisolated static func trash(path: String, in root: String) -> String? {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
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

    private nonisolated static func failure(
        _ run: (status: Int32, stdout: String, stderr: String), path: String
    ) -> String {
        let text = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text ?? String(localized: "Unable to revert \(path)")
    }

    private nonisolated static func trimmedLine(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
