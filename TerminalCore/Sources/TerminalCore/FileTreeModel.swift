//
//  FileTreeModel.swift
//  TerminalCore
//

import Combine
import Foundation

/// Flattened, lazily-expanded view of a directory tree, on this machine or on
/// the host a terminal has ssh'd into.
@MainActor
public final class FileTreeModel: nonisolated ObservableObject {
    /// How the tree tells the user an operation failed — a rename onto a name
    /// that is taken, a folder that could not be written.
    ///
    /// Injected rather than put up here, because an alert is the view layer's
    /// business and because a rename against a temp directory has to be
    /// checkable without one. There is no default: a model that silently
    /// swallowed its failures would look like a rename that did nothing.
    public typealias FailureReporter = @MainActor (_ message: String, _ detail: String) -> Void

    private let reportFailure: FailureReporter

    public init(reportFailure: @escaping FailureReporter) {
        self.reportFailure = reportFailure
    }

    public struct Item: Identifiable, Equatable {
        public var id: String { path }
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let depth: Int
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        public var isDraft = false
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    public struct Draft: Equatable {
        let parentDir: String
        public let isDirectory: Bool
    }

    /// Which machine the rows describe.
    ///
    /// A local tree is read straight off the file system while the panel is
    /// being laid out: `contentsOfDirectory` on a warm directory is
    /// microseconds, and the panel already re-reads on a two-second timer. A
    /// remote tree cannot work that way — every listing is an ssh round trip —
    /// so its rows come from a cache that fills in behind the view.
    public enum Source: Equatable {
        case local
        case remote(RemoteShellDestination)
    }

    /// What the panel has to say beyond its rows.
    public enum Status: Equatable {
        case ready
        /// A remote listing is in flight and there is nothing to show yet.
        case loading
        /// The host could not be reached. The tree stays as it is and the
        /// panel shows this instead, until the user retries or the terminal
        /// moves somewhere else.
        case unreachable(String)
        /// The terminal is sitting in a folder the user has put out of
        /// Terminal's reach — see ``ProtectedDirectories``. Distinct from an
        /// empty listing, which is what an unexplained blank panel would look
        /// like here.
        case restricted
    }

    @Published public private(set) var rootPath = ""
    @Published public private(set) var items: [Item] = []
    @Published public private(set) var source = Source.local
    @Published public private(set) var status = Status.ready
    /// Path of the row currently being renamed inline, if any.
    @Published public private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    @Published public private(set) var draft: Draft?
    private var expanded: Set<String> = []

    /// Listings fetched from a remote host, with when they arrived. Cleared
    /// whenever the tree changes host.
    private var remoteListings: [String: (entries: [Entry], loadedAt: Date)] = [:]
    private var pendingDirectories: Set<String> = []
    /// Where an ssh login lands, learned from the first listing, so the tree
    /// has somewhere to root when the host could not say where the terminal
    /// is. Cleared with the listings when the tree changes host.
    private var loginDirectory: String?
    /// Bumped whenever the host or root changes, so a listing that arrives
    /// after the terminal moved on is discarded rather than shown.
    private var generation: UInt = 0

    /// How long a remote listing is trusted before the panel's next tick
    /// re-fetches it. Long enough that sitting on an expanded tree is not a
    /// steady stream of commands, short enough that a build dropping files
    /// into a folder shows up while the user is still looking at it.
    private static let remoteRefreshInterval: TimeInterval = 10

    /// A directory's contents, from either machine — the remote service's shape
    /// is exactly what the local read produces, so there is nothing to convert.
    private typealias Entry = RemoteFileService.Entry

    public var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    /// The connection the rows come from, when they do not come from this
    /// machine. Passed along when a row is opened so the tab reads the file
    /// over the same connection.
    public var remoteDestination: RemoteShellDestination? {
        guard case .remote(let destination) = source else { return nil }
        return destination
    }

    /// The host whose files are shown, when they are not this machine's.
    public var remoteHost: String? { remoteDestination?.host }

    /// Whether the tree can be edited. Terminal only creates, renames, and
    /// trashes files it can reach through the file system.
    public var isEditable: Bool { source == .local }

    public func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    /// Points the tree at `root` on this machine (collapsing everything if it
    /// moved) and re-reads visible directories. Cheap when nothing changed.
    public func sync(root: String) {
        leaveHost(unless: .local)
        move(to: root, source: .local)
        // Set on every sync rather than only on a move: the setting can be
        // turned off while the tree is already pointed at a guarded folder,
        // and the next tick is what has to notice.
        status = ProtectedDirectories.denies(root) ? .restricted : .ready
        rebuild()
    }

    /// Points the tree at a directory on the host a terminal has ssh'd into.
    ///
    /// `directory` is where the terminal has got to on that host, once the
    /// session has established it — see ``TerminalSession/remoteRoot(on:)``.
    /// When it could not be established the tree roots at the directory an ssh
    /// login lands in: the far side of the connection is still browsable, it
    /// just does not follow the remote `cd`.
    public func sync(remote destination: RemoteShellDestination, directory: String?) {
        leaveHost(unless: .remote(destination))
        guard let root = directory ?? loginDirectory else {
            move(to: "", source: .remote(destination))
            if status == .ready { status = .loading }
            // The listing reports the directory it ran in, so asking for the
            // login directory by name first would be a round trip spent
            // learning something the next one says anyway.
            requestRemoteListing(of: Self.loginDirectoryRequest, from: destination)
            rebuild()
            return
        }
        move(to: root, source: .remote(destination))
        rebuild()
    }

    /// Hangs up on the host the tree is leaving, if it is leaving one.
    ///
    /// Closing the master here rather than letting it lapse keeps a connection
    /// from outliving the reason it existed by the whole `ControlPersist`
    /// window — the user exited ssh, or the panel followed another session.
    private func leaveHost(unless next: Source) {
        guard source != next, case .remote(let previous) = source else { return }
        Task.detached(priority: .utility) { RemoteFileService.disconnect(from: previous) }
        remoteListings = [:]
        loginDirectory = nil
        status = .ready
    }

    /// Tries the host again after a failure. The tree is otherwise left alone
    /// once a connection fails, so a host that is down does not become an ssh
    /// attempt every two seconds for as long as the panel is open.
    public func retry() {
        guard case .unreachable = status else { return }
        status = .ready
        remoteListings = [:]
        // The first connection to a host fails before the tree has a root, and
        // `rebuild` has no tree to walk in that state — so nothing would be
        // asked for again. That is also the likeliest failure there is: a host
        // that is down, or one that wanted a password.
        guard case .remote(let destination) = source, rootPath.isEmpty else {
            rebuild()
            return
        }
        status = .loading
        requestRemoteListing(of: Self.loginDirectoryRequest, from: destination)
    }

    private func move(to root: String, source newSource: Source) {
        guard root != rootPath || newSource != source else { return }
        rootPath = root
        source = newSource
        expanded = []
        // Any in-progress inline edit belonged to the old tree.
        renamingPath = nil
        draft = nil
        // Requests already in flight will be discarded on arrival, so their
        // directories have to stop counting as pending or nothing would ever
        // ask for them again.
        pendingDirectories = []
        generation &+= 1
    }

    /// Whether this row is a folder Terminal has been told to stay out of.
    /// The panel draws it locked rather than hiding it: the folder is really
    /// there, and a row that vanished would read as a folder that is gone.
    public func isRestricted(_ item: Item) -> Bool {
        source == .local && ProtectedDirectories.denies(item.path)
    }

    public func toggle(_ item: Item) {
        guard item.isDirectory, !isRestricted(item) else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        rebuild()
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    ///
    /// The editing operations all guard on ``isEditable`` rather than trusting
    /// the panel to have hidden them: a remote row's path is an absolute path
    /// on the *other* machine, and running one of these against it would
    /// quietly rename or trash whatever happens to sit at the same path here.
    public func moveToTrash(_ item: Item) {
        guard isEditable else { return }
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: item.path), resultingItemURL: nil
            )
            expanded.remove(item.path)
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.", bundle: .module,
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        rebuild()
    }

    // MARK: - Rename

    public func beginRename(_ item: Item) {
        guard isEditable else { return }
        renamingPath = item.path
    }

    public func cancelRename() {
        renamingPath = nil
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    public func rename(_ item: Item, to newName: String) -> String? {
        renamingPath = nil
        guard isEditable else { return nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”.", bundle: .module),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", bundle: .module)
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        guard caseOnlyChange || !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”.", bundle: .module),
                String(localized: "An item named “\(trimmed)” already exists here.", bundle: .module)
            )
            return nil
        }
        do {
            try fm.moveItem(atPath: item.path, toPath: dest)
            remapExpanded(from: item.path, to: dest)
        } catch {
            presentError(String(localized: "Couldn’t rename to “\(trimmed)”.", bundle: .module), error.localizedDescription)
            return nil
        }
        rebuild()
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    public func beginNewFile(in directory: String) {
        startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    public func beginNewFolder(in directory: String) {
        startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) {
        guard isEditable else { return }
        renamingPath = nil
        draft = Draft(parentDir: directory, isDirectory: isDirectory)
        // Reveal the folder's contents so the input row is visible.
        expanded.insert(directory)
        rebuild()
    }

    public func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
        rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    public func commitDraft(name: String) -> String? {
        guard let draft else { return nil }
        self.draft = nil
        guard isEditable else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rebuild(); return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”.", bundle: .module),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", bundle: .module)
            )
            rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”.", bundle: .module),
                String(localized: "An item named “\(trimmed)” already exists here.", bundle: .module)
            )
            rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } catch {
                presentError(String(localized: "Couldn’t create the folder.", bundle: .module), error.localizedDescription)
            }
        } else if fm.createFile(atPath: dest, contents: nil) {
            createdFile = dest
        } else {
            presentError(
                String(localized: "Couldn’t create the file.", bundle: .module),
                String(localized: "It could not be written to disk.", bundle: .module)
            )
        }
        rebuild()
        return createdFile
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        reportFailure(messageText, informativeText)
    }

    private func rebuild() {
        // No root yet — a remote tree waiting to learn where it starts. The
        // rows from wherever the tree was pointed before are not this host's.
        guard !rootPath.isEmpty else {
            items = []
            return
        }
        var out: [Item] = []
        appendChildren(of: rootPath, depth: 0, into: &out)
        if out != items {
            items = out
        }
    }

    private func appendChildren(of dir: String, depth: Int, into out: inout [Item]) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth, isDraft: true
                )
            )
        }
        guard let entries = entries(in: dir) else { return }

        let children = entries
            .filter { $0.name != ".git" }
            .map { entry in
                Item(
                    name: entry.name,
                    path: (dir as NSString).appendingPathComponent(entry.name),
                    isDirectory: entry.isDirectory,
                    depth: depth
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        for child in children {
            out.append(child)
            if child.isDirectory, expanded.contains(child.path) {
                appendChildren(of: child.path, depth: depth + 1, into: &out)
            }
        }
    }

    /// The contents of `dir`, or nil when there are none to show yet — an
    /// unreadable directory locally, a listing still in flight remotely.
    private func entries(in dir: String) -> [Entry]? {
        switch source {
        case .local:
            // Before the listing, not after: reading a guarded folder is what
            // raises the privacy prompt, so the refusal has to come first.
            guard !ProtectedDirectories.denies(dir) else { return nil }
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
            return names.map { name in
                let path = (dir as NSString).appendingPathComponent(name)
                // A guarded child is one of the folders macOS names, all of
                // which are directories — reported as one without asking, so
                // that drawing the row of a folder we won't open doesn't
                // become the one call that touches it.
                guard !ProtectedDirectories.denies(path) else {
                    return Entry(name: name, isDirectory: true)
                }
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDirectory)
                return Entry(name: name, isDirectory: isDirectory.boolValue)
            }
        case .remote(let destination):
            guard let listing = remoteListings[dir] else {
                requestRemoteListing(of: dir, from: destination)
                return nil
            }
            if Date().timeIntervalSince(listing.loadedAt) > Self.remoteRefreshInterval {
                requestRemoteListing(of: dir, from: destination)
            }
            return listing.entries
        }
    }

    // MARK: - Remote listings

    /// The directory an ssh login lands in, asked for by the only name that
    /// works before its real one is known.
    private static let loginDirectoryRequest = "."

    private func requestRemoteListing(
        of dir: String, from destination: RemoteShellDestination
    ) {
        // A host that just refused a connection would otherwise be asked again
        // on the panel's next tick, and on every tick after that.
        guard !isUnreachable, pendingDirectories.insert(dir).inserted else { return }
        // An empty panel with no rows and no explanation reads as "this host
        // has no files"; say the connection is still being made instead.
        if items.isEmpty, status == .ready { status = .loading }
        let generation = generation

        Task { [weak self] in
            let listing = await Task.detached(priority: .utility) {
                // Nothing is watching for this any more; do not pay for the
                // connection. Only what the caller can already cancel reaches
                // here early enough for this to fire.
                guard !Task.isCancelled else { return nil as Result<RemoteFileService.Listing, RemoteFileService.Failure>? }
                return RemoteFileService.attempt { try RemoteFileService.entries(in: dir, on: destination) }
            }.value
            guard let self, let listing, self.generation == generation else { return }
            self.pendingDirectories.remove(dir)
            switch listing {
            case .success(let contents):
                self.remoteListings[contents.directory] = (contents.entries, Date())
                if self.status == .loading { self.status = .ready }
                // The listing names the directory it actually ran in, which is
                // how the tree learns where an ssh login lands without having
                // spent a round trip asking.
                if dir == Self.loginDirectoryRequest {
                    self.loginDirectory = contents.directory
                    self.sync(remote: destination, directory: nil)
                    return
                }
            case .failure(let failure):
                self.recordRemoteFailure(failure, atPath: dir)
            }
            self.rebuild()
        }
    }

    /// A directory that is merely gone is remembered as empty, so the tree
    /// stops asking for it. A host that cannot be reached stops the tree.
    private func recordRemoteFailure(
        _ failure: RemoteFileService.Failure, atPath dir: String
    ) {
        switch failure {
        case .pathUnavailable(let message):
            // The root itself being unreadable is not one folder failing —
            // there is no tree left to show.
            guard dir != Self.loginDirectoryRequest, dir != rootPath else {
                status = .unreachable(message)
                return
            }
            remoteListings[dir] = ([], Date())
        case .unreachable(let message):
            status = .unreachable(message)
        }
    }

    private var isUnreachable: Bool {
        if case .unreachable = status { return true }
        return false
    }
}
