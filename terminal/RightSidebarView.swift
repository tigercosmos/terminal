//
//  RightSidebarView.swift
//  terminal
//

import AppKit
import SwiftUI
import TerminalCore

/// How the file tree reports a failed rename, create, or delete. The model
/// itself has no window — see ``FileTreeModel/FailureReporter`` — so the alert
/// lives out here with the rest of the view layer.
private func presentFileTreeFailure(_ message: String, _ detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.runModal()
}

/// Right sidebar: hidden by default, toggled from the terminal's corner
/// button or ⇧⌘B. Files/Git switch via tabs along its top, otty-style.
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    /// Owned by the window rather than this panel: the toolbar shows the same
    /// repository and stays visible while the panel is closed.
    @ObservedObject var git: GitStatusModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @StateObject private var fileTree = FileTreeModel(reportFailure: presentFileTreeFailure)
    @StateObject private var compare = GitCompareModel()
    @StateObject private var info = SessionInfoModel()
    @State private var applicationIsActive = NSApp.isActive
    /// Which rule produced the current panel root; drives the Files badge.
    @State private var rootSource = Project.PanelRootSource.shell
    @AppStorage("rightSidebarWidth") private var width: Double = 240

    private var pollsSelectedPanel: Bool {
        guard manager.isPanelVisible, applicationIsActive else { return false }
        switch manager.panelTab {
        case .files, .info:
            return true
        // Git and Compare are event-driven for a repository on this machine:
        // both read every changed file, so they refresh when a terminal or Git
        // command completes rather than on a two-second timer. A terminal
        // sitting inside `ssh` completes no commands until the user comes back
        // out of it, so a repository on another machine is polled instead — at
        // the models' own interval, not on every tick.
        case .git:
            return git.remote != nil
        case .compare:
            return compare.remote != nil
        }
    }

    /// Every terminal in the selected project can change the same repository.
    /// Watching only these counters avoids reacting to prompt/input lifecycle
    /// updates while still catching commands completed in an unfocused pane.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    /// Path of the file in the focused pane, so the tree can highlight it.
    /// Reactive: focus/selection is published up through the project to `manager`.
    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.focusedContent {
            return file.path
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isPanelVisible {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    tabBar
                    switch manager.panelTab {
                    case .files:
                        filesPanel
                    case .git:
                        GitPanel(
                            model: git,
                            session: manager.selectedSession,
                            openFile: { manager.openFile($0, remote: git.remote) },
                            openToSide: { manager.openFileToSide($0, remote: git.remote) },
                            openDiff: { entry, staged in
                                manager.openDiff(
                                    repository: git.repoDirectory,
                                    path: entry.path,
                                    staged: staged,
                                    untracked: entry.isUntracked,
                                    origPath: entry.origPath
                                )
                            },
                            openCommitFile: { commit, file in
                                manager.openCommitDiff(
                                    repository: git.repoDirectory,
                                    path: file.path,
                                    origPath: file.originalPath,
                                    commitHash: commit.hash,
                                    parentHash: commit.parentHash,
                                    shortHash: commit.shortHash
                                )
                            }
                        )
                    case .compare:
                        ComparePanel(
                            model: compare,
                            openFile: { manager.openFile($0, remote: compare.remote) },
                            openToSide: { manager.openFileToSide($0, remote: compare.remote) },
                            openCompare: { entry, target in
                                manager.openCompare(
                                    repository: compare.repoDirectory,
                                    path: entry.path,
                                    origPath: entry.origPath,
                                    targetOID: target.oid,
                                    targetName: target.name
                                )
                            }
                        )
                    case .info:
                        InfoPanel(model: info, session: manager.selectedSession)
                    }
                }
                .frame(width: width)
                .background(Color(nsColor: Theme.sidebar))
                // Tells zoom that clicks landing here are aimed at the interface.
                .background(InterfaceRegionReporter())
            }
        }
        .overlay(alignment: .leading) {
            if manager.isPanelVisible {
                SidebarResizeHandle(
                    edge: .leading,
                    width: $width,
                    range: 180...500,
                    defaultWidth: 240
                )
            }
        }
        .onAppear { syncModels() }
        // Files and process information remain live while visible. Git is
        // event-driven: terminal/Git command completion and app activation
        // refresh it without a repeating main-run-loop source.
        .task(id: pollsSelectedPanel) {
            guard pollsSelectedPanel else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                syncModels(refreshGitStatus: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            applicationIsActive = true
            syncModels()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            applicationIsActive = false
        }
        // Every panel now moves when a command finishes: Git and Compare list
        // what changed, Files carries the same status decorations, and Info
        // lists the processes that just came and went.
        .onChange(of: commandCompletionSequences) {
            syncModels()
        }
        .onChange(of: manager.isPanelVisible) { syncModels() }
        .onChange(of: manager.panelTab) { syncModels() }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once so automatically rooted
        // panels follow the terminal without waiting for another event.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
        // Same for pinning/unpinning the project directory.
        .onChange(of: manager.selectedProject?.customDirectory) { syncModels() }
        .environment(
            \.sidebarFontScale,
            CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize)
        )
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.sidebarFontSize)))
    }

    /// Built here rather than inline in the panel switch: as one branch of that
    /// expression it is large enough for the type checker to give up on.
    private var filesPanel: some View {
        FileTreePanel(
            model: fileTree,
            git: git,
            session: manager.selectedSession,
            rootBadge: rootBadge,
            currentFilePath: openFilePath,
            openFile: { manager.openFile($0, remote: fileTree.remoteDestination) },
            openToSide: { manager.openFileToSide($0, remote: fileTree.remoteDestination) },
            onRename: { manager.fileRenamed(from: $0, to: $1) },
            refreshGitStatus: { git.refresh() }
        )
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(
                .info,
                systemImage: "info.circle",
                title: String(localized: "Info"),
                help: String(localized: "Info (⇧⌘I)")
            )
            tabButton(
                .files,
                systemImage: "folder",
                title: String(localized: "Files"),
                help: String(localized: "Files (⇧⌘E)")
            )
            tabButton(
                .git,
                systemImage: "arrow.triangle.branch",
                title: String(localized: "Git"),
                help: String(localized: "Git (⇧⌘G)")
            )
            tabButton(
                .compare,
                systemImage: "arrow.left.and.right",
                title: String(localized: "Compare"),
                help: String(localized: "Compare against a branch or commit (⇧⌘C)")
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func tabButton(_ panel: RightPanel, systemImage: String, title: String, help: String) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .sidebarFont(size: 10, weight: .medium)
                Text(title)
                    .sidebarFont(size: 11, weight: .regular)
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.12) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    private func syncModels(refreshGitStatus: Bool = true) {
        guard manager.isPanelVisible,
              let project = manager.selectedProject,
              let session = project.selectedSession
        else { return }
        let cwd = session.currentDirectoryPath
        // Files and Git anchor to the project directory — pinned when the
        // user set one, else the repository the session is working in — so
        // they don't re-root as the terminal cds around a repo; Info
        // describes the shell itself, showing its live cwd next to that root.
        // An agent that moves to its own worktree changes only its own
        // process directory, so the foreground job's cwd is passed in too.
        let (root, source) = project.panelRoot(
            followingSessionAt: cwd, foregroundAt: session.foregroundDirectoryPath
        )
        if rootSource != source { rootSource = source }
        // Files, Git, and Compare all follow the terminal onto another machine,
        // and all three stop doing so when the user has pinned a directory for
        // the project — a pin is an explicit choice about what these panels are
        // for. Asking costs three syscalls, so it is asked once here rather
        // than inside each panel.
        let remote = source == .pinned ? nil : session.remoteDestination
        // Where the panels look: a directory on this Mac, or wherever the
        // terminal has got to on the host it has ssh'd into. The session
        // establishes that once for all three panels, since it takes asking
        // the host.
        let panelRoot = remote.map { PanelRoot.remote(session.remoteRoot(on: $0), $0) }
            ?? .local(root)
        switch manager.panelTab {
        case .files:
            guard let remote else {
                // Git status backs this tree's decorations, and the window
                // keeps it current for the toolbar already — no sync here.
                fileTree.sync(root: root)
                return
            }
            // With no directory established yet, the tree learns the login
            // directory from the first listing it makes rather than waiting.
            fileTree.sync(remote: remote, directory: panelRoot.provisionalPath.isEmpty
                ? nil : panelRoot.provisionalPath)
        // `refreshGitStatus` is false only on a timer tick, which is what the
        // models rate-limit a remote re-read against.
        case .git:
            // The window owns this model and already refreshes it on every
            // user-driven trigger, for the toolbar as much as this panel.
            // Only the timer tick — which is how a repository on another
            // machine stays current — is still this panel's to drive.
            if !refreshGitStatus { git.sync(root: panelRoot, polling: true) }
        case .compare:
            compare.sync(root: panelRoot, polling: !refreshGitStatus)
        case .info:
            info.sync(
                root: cwd, projectRoot: root, projectRootSource: source,
                shellName: session.shellName, shellPid: session.shellPid
            )
        }
    }

    /// Text badge for the Files header while the tree is not simply showing
    /// the shell's own directory: the host it has ssh'd into, the agent's
    /// worktree, or a plain "job" when the foreground process moved somewhere
    /// that isn't a linked worktree. The label and its spoken description
    /// travel together so neither is assembled from translated fragments.
    private var rootBadge: (text: String, description: String)? {
        // Where the tree is pointed is the tree's own business — `rootSource`
        // describes the project directory, which stays on this machine even
        // while the file panel is showing another one.
        if fileTree.remoteHost != nil {
            return (
                String(
                    localized: "ssh",
                    comment: "Files header badge: the file tree is showing the host the terminal has connected to."
                ),
                String(localized: "Showing files on the host this terminal is connected to")
            )
        }
        guard case .foreground(let isWorktree) = rootSource else { return nil }
        if isWorktree {
            return (
                String(
                    localized: "worktree",
                    comment: "Files header badge: the panels follow a Git worktree the terminal’s foreground job moved to."
                ),
                String(localized: "Following the terminal job’s worktree")
            )
        }
        return (
            String(
                localized: "job",
                comment: "Files header badge: the panels follow a directory the terminal’s foreground job moved to, outside any worktree of the shell’s repository."
            ),
            String(localized: "Following the terminal job’s directory")
        )
    }
}

// MARK: - Shared panel chrome

struct PanelHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .sidebarFont(size: 12, weight: .semibold)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File tree

private struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    let session: TerminalSession?
    /// Set while the tree follows the terminal's foreground job into another
    /// checkout, so the header says why the root moved.
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void

    /// The path under the folder name, prefixed with the host when the tree is
    /// not describing this machine — the same `host:/path` shape scp uses, so
    /// there is no reading a remote path as a local one.
    private var subtitle: String {
        guard let host = model.remoteHost else { return model.rootPath }
        return "\(host):\(model.rootPath)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: subtitle)
                if let rootBadge {
                    Text(verbatim: rootBadge.text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.09))
                        )
                        .accessibilityLabel(rootBadge.description)
                }
                if model.isEditable {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .sidebarFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            switch model.status {
            case .loading:
                statusMessage(Text("Connecting…"))
            case .unreachable(let reason):
                unreachable(reason)
            case .ready:
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.items) { item in
                            FileTreeRow(
                                model: model, git: git, item: item, session: session,
                                currentFilePath: currentFilePath,
                                openFile: openFile, openToSide: openToSide, onRename: onRename,
                                refreshGitStatus: refreshGitStatus
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func statusMessage(_ text: Text) -> some View {
        text
            .sidebarFont(size: 11)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 12)
    }

    /// ssh's own diagnostic is shown verbatim rather than paraphrased: "no
    /// such identity" and "host key verification failed" each need a different
    /// thing done about them, and only ssh knows which one happened.
    private func unreachable(_ reason: String) -> some View {
        VStack(spacing: 8) {
            Text("Terminal couldn’t read files on this host.")
                .sidebarFont(size: 11)
                .foregroundStyle(.secondary)
            Text(verbatim: reason)
                .sidebarFont(size: 10, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Try Again") { model.retry() }
                .sidebarFont(size: 11)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    @ObservedObject private var themeChanges = Theme.changes
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void

    @State private var isHovering = false
    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    /// Git status belongs to the checkout on this machine. A remote row's path
    /// could collide with one in it, and a badge from the wrong repository is
    /// worse than none.
    private var gitDecoration: GitStatusModel.FileDecoration? {
        guard model.isEditable else { return nil }
        return git.fileDecoration(for: item.path, isDirectory: item.isDirectory)
    }

    var body: some View {
        if item.isDraft {
            // The transient new-file/folder input row: no hover/menu, no
            // backing file to act on.
            draftRow
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isCurrent ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.05) : .clear))
                )
                .onHover { isHovering = $0 }
                .contextMenu { rowMenu }
        }
    }

    /// A remote row's path names a file on the other machine, so everything
    /// that would hand it to macOS or to the file system is left out. `cd`
    /// stays: the terminal it would be typed into is already on that host.
    @ViewBuilder
    private var rowMenu: some View {
        if !item.isDirectory {
            Button("Open") {
                openFile(item.path)
            }
            Button("Open to the Side") {
                openToSide(item.path)
            }
        }
        if model.isEditable {
            Button("Open in Default App") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if let host = model.remoteHost {
            Button("Copy Path with Host") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(host):\(item.path)", forType: .string)
            }
        }
        if item.isDirectory {
            Button("cd Here") {
                session?.sendCommand("cd " + shellQuote(item.path) + "\n")
            }
            if model.isEditable {
                Divider()
                Button("New File…") {
                    model.beginNewFile(in: item.path)
                }
                Button("New Folder…") {
                    model.beginNewFolder(in: item.path)
                }
            }
        }
        if model.isEditable {
            Divider()
            Button("Rename") {
                model.beginRename(item)
            }
            Button("Move to Trash", role: .destructive) {
                model.moveToTrash(item)
                refreshGitStatus()
            }
        }
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        if let newPath = model.rename(item, to: editingName) {
            onRename(oldPath, newPath)
            refreshGitStatus()
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        if let created = model.commitDraft(name: editingName) {
            openFile(created)
        }
        refreshGitStatus()
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            renameRow
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            if item.isDirectory {
                model.toggle(item)
            } else {
                openFile(item.path)
            }
        } label: {
            HStack(spacing: 5) {
                leadingGlyphs
                Text(item.name)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(fileNameColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let gitDecoration {
                    Text(gitDecoration.badge)
                        .sidebarFont(size: 9, weight: .semibold, design: .monospaced)
                        .foregroundStyle(gitDecoration.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(item.depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fileAccessibilityLabel)
        // Drag a row out as a file URL: onto the terminal (which inserts its
        // path) or into Finder and other apps. A click still opens/toggles;
        // the drag only begins once the pointer moves.
        //
        .onDrag {
            // Only for a row that is a file on this machine. A remote row's
            // path names nothing here, and handing another application a
            // `file://` URL built from it would offer up whatever happens to
            // sit at that path locally as though it were the file on screen.
            guard model.isEditable else { return NSItemProvider() }
            return NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
        }
    }

    private var fileNameColor: Color {
        if let gitDecoration { return gitDecoration.color }
        return item.name.hasPrefix(".") ? Color.secondary.opacity(0.55) : .secondary
    }

    private var fileAccessibilityLabel: String {
        guard let gitDecoration else { return item.name }
        return item.name + ", " + gitDecoration.accessibilityName
    }

    private var renameRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(String(localized: "Name"))
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(item.isDirectory
                ? String(localized: "Folder name")
                : String(localized: "File name"))
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) { model.cancelDraft(); return .handled }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .sidebarFont(size: 11.5)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.accent).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory && !item.isDraft {
                Image(systemName: "chevron.right")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .sidebarFont(size: 10)
                    .foregroundStyle(Color(nsColor: Theme.accent).opacity(0.8))
                    .frame(width: 14)
            } else {
                MaterialFileIconView(path: item.path, size: 14)
                    .frame(width: 14)
            }
        }
    }
}

private extension GitStatusModel.FileDecoration {
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflict: "!"
        case .ignored: "I"
        }
    }

    var accessibilityName: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        }
    }

    var color: Color {
        switch self {
        case .modified: Color(red: 0.82, green: 0.60, blue: 0.13)
        case .added, .untracked: Color(red: 0.25, green: 0.73, blue: 0.31)
        case .deleted: Color(red: 1.0, green: 0.48, blue: 0.45)
        case .renamed, .copied: Color(red: 0.35, green: 0.65, blue: 1.0)
        case .conflict: Color(red: 0.74, green: 0.55, blue: 1.0)
        case .ignored: Color.secondary.opacity(0.55)
        }
    }
}

// MARK: - Git panel

private struct GitPanel: View {
    @ObservedObject private var themeChanges = Theme.changes

    private enum EntryOperation: Equatable {
        case stage
        case unstage
        case discard
    }

    /// Which control started the running operation, so its own spinner can
    /// replace its icon. A single banner saying "something is happening"
    /// leaves you looking for what — this points at it.
    private enum OperationTrigger: Equatable {
        case branchMenu
        case moreMenu
        case primaryAction
        case commitMenu
        case syncButton
        case stageAll
        case unstageAll
        case discardAll
        case entry(path: String, operation: EntryOperation)
        case initializeRepository
    }

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
    }

    @ObservedObject var model: GitStatusModel
    let session: TerminalSession?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void
    /// Opens one file as it changed in a historical commit.
    let openCommitFile: (
        _ commit: GitStatusModel.RecentCommit,
        _ file: GitStatusModel.RecentCommit.FileChange
    ) -> Void

    @State private var commitMessage = ""
    @State private var pendingDiscard: PendingDiscard?
    @State private var pendingDiscardAll: [PendingDiscard] = []
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false
    @State private var historyCollapsed = true
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var operationExpanded = false
    @State private var operationTrigger: OperationTrigger?

    var body: some View {
        VStack(spacing: 0) {
            header
            operationFailureBanner

            if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…"))
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                if model.isEditable {
                    commitBox
                } else {
                    readOnlyNotice
                }
                filterBar
                changeList
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard?.entry),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardActionTitle(for: pendingDiscard?.entry),
                   role: .destructive) {
                if let pendingDiscard {
                    if discardSnapshotIsCurrent(pendingDiscard) {
                        performOperation(
                            .entry(path: pendingDiscard.entry.path, operation: .discard)
                        ) {
                            model.discard(pendingDiscard.entry)
                        }
                    } else {
                        model.cancelStaleDiscard()
                    }
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files go to the Trash.",
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 { pendingDiscardAll = [] }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard All Changes", role: .destructive) {
                let snapshot = pendingDiscardAll
                if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    performOperation(.discardAll) {
                        model.discardChanges(snapshot.map(\.entry))
                    }
                } else {
                    model.cancelStaleDiscard()
                }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
        .onChange(of: model.isBusy) {
            if !model.isBusy { operationTrigger = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchLabel
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .sidebarFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(title: String(localized: "Git"), subtitle: model.displayPath)
            }
            // Only surface progress for user operations and initial repository
            // discovery. Event-driven refreshes retain the resolved content.
            // A user's operation reports itself in the control that started
            // it. Repository discovery stays here, because it has no control
            // behind it to report from.
            if model.isResolvingInitialStatus {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(String(localized: "Refreshing Git status"))
            }
            if model.isRepo {
                headerButton(
                    "line.3.horizontal.decrease",
                    help: String(localized: "Filter Changed Files"),
                    disabled: false
                ) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                headerButton(
                    "arrow.clockwise",
                    help: String(localized: "Refresh Git Status"),
                    disabled: model.isBusy || model.isResolvingInitialStatus
                ) {
                    model.refresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Why the panel is showing a repository it will not act on. Stated once,
    /// where the commit box would be, rather than as a disabled control per
    /// action — matching the remote file tree, which simply has no editing
    /// commands rather than greyed-out ones.
    private var readOnlyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .sidebarFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Read-only: this repository is on \(model.remoteHost ?? "").")
                .sidebarFont(size: 10)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var branchLabel: some View {
        if model.isEditable {
            branchMenu
        } else {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .sidebarFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(
                    title: model.branch ?? String(localized: "Detached HEAD"),
                    subtitle: model.displayPath
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD"))")
            )
        }
    }

    private var branchMenu: some View {
        Menu {
            if !model.branches.isEmpty {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        performOperation(.branchMenu) {
                            model.switchBranch(to: branch)
                        }
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isBusy)
                }
                Divider()
            }
            Button("Create New Branch…") {
                presentCreateBranchDialog()
            }
            .disabled(model.isBusy)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "arrow.triangle.branch")
                        .sidebarFont(size: 11, weight: .medium)
                        .foregroundStyle(Color(nsColor: Theme.accent))
                        .opacity(operationIsLoading(.branchMenu) ? 0 : 1)
                    if operationIsLoading(.branchMenu) {
                        operationProgressView()
                    }
                }
                PanelHeader(
                    title: model.branch ?? String(localized: "Detached HEAD"),
                    subtitle: model.displayPath
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Switch or Create Branch")
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD"))")
        )
    }

    private var moreMenu: some View {
        Menu {
            if model.isEditable {
                remoteActions
                Divider()
            }
            Button("Copy Changed Paths") { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            // The bare path is what pastes correctly into the terminal the
            // user is already in — on the far side, for a remote repository.
            // The host-qualified form is the one that survives leaving it, so
            // both are offered rather than guessing which is meant.
            Button("Copy Repository Path") { copyToPasteboard(model.repoRoot) }
            if !model.isEditable {
                Button("Copy Repository Path with Host") {
                    copyToPasteboard(model.repoDirectory.displayPath)
                }
            }
            if model.isEditable {
                Button("Reveal Repository in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: model.repoRoot)]
                    )
                }
            }
        } label: {
            ZStack {
                Image(systemName: "ellipsis")
                    .sidebarFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.moreMenu) ? 0 : 1)
                if operationIsLoading(.moreMenu) {
                    operationProgressView()
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions…")
        .accessibilityLabel("More Git Actions")
    }

    /// The actions that change the repository. Only offered for a checkout on
    /// this machine.
    @ViewBuilder
    private var remoteActions: some View {
        Button("Fetch") { performOperation(.moreMenu, model.fetch) }
            .disabled(model.isBusy || model.remotes.isEmpty)
        Button("Pull (Fast-forward Only)") { performOperation(.moreMenu, model.pull) }
            .disabled(model.isBusy || !model.hasUpstream)
        if model.hasUpstream {
            Button("Push") { performOperation(.moreMenu, model.push) }
                .disabled(model.isBusy)
        } else if model.remotes.count > 1 {
            Menu("Publish Branch to") {
                ForEach(model.remotes, id: \.self) { remote in
                    Button(remote) {
                        performOperation(.moreMenu) { model.publish(to: remote) }
                    }
                }
            }
            .disabled(model.isBusy || model.branch == "detached HEAD")
        } else {
            Button("Publish Branch") { performOperation(.moreMenu, model.push) }
                .disabled(model.isBusy || model.remotes.isEmpty || model.branch == "detached HEAD")
        }
        Button("Sync Changes") { performOperation(.moreMenu, model.syncChanges) }
            .disabled(
                model.isBusy || model.remotes.isEmpty
                    || (!model.hasUpstream && model.remotes.count != 1)
                    || model.branch == "detached HEAD"
            )
        Divider()
        Button("Stash All Changes") {
            performOperation(.moreMenu) { model.stash(includeUntracked: true) }
        }
            .disabled(model.isBusy || model.totalChangeCount == 0)
        Button(
            model.stashCount == 1
                ? String(localized: "Pop Stash")
                : String(localized: "Pop Stash (\(model.stashCount))")
        ) {
            performOperation(.moreMenu, model.stashPop)
        }
        .disabled(model.isBusy || model.stashCount == 0)
    }

    private func headerButton(
        _ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .sidebarFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(verbatim: model.upstream ?? (branch == "detached HEAD"
                    ? String(localized: "Detached HEAD")
                    : String(localized: "Unpublished branch")))
                    .sidebarFont(size: 9.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.behind > 0 {
                    badge(
                        "↓\(model.behind)",
                        label: String(localized: "\(model.behind) incoming commits")
                    )
                }
                if model.ahead > 0 {
                    badge(
                        "↑\(model.ahead)",
                        label: String(localized: "\(model.ahead) outgoing commits")
                    )
                }
            }
            .frame(height: 17)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Repository and operation state

    @ViewBuilder
    private var repositoryOperationBanner: some View {
        if let current = model.repositoryOperation {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .sidebarFont(size: 10, weight: .semibold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: current)
                        .sidebarFont(size: 10.5, weight: .medium)
                    Text(model.mergeEntries.isEmpty
                         ? String(localized: "Finish or abort from the terminal")
                         : String(
                            localized: "Resolve and stage \(model.mergeEntries.count) conflicted files",
                            comment: "Git merge guidance. The placeholder is the number of conflicted files."
                         ))
                        .sidebarFont(size: 9.5)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 0.74, green: 0.55, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.74, green: 0.55, blue: 1.0).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .accessibilityElement(children: .combine)
        }
    }

    /// Failures only. A running or succeeded operation reports itself in the
    /// control that started it, which is where you are already looking; a
    /// banner for those just moved the news somewhere else.
    @ViewBuilder
    private var operationFailureBanner: some View {
        if let operation = model.operation, case .failed = operation.state {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .sidebarFont(size: 10)
                    Text(operation.statusLabel)
                        .sidebarFont(size: 10.5, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !operation.output.isEmpty {
                        Button {
                            operationExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .sidebarFont(size: 8, weight: .semibold)
                                .rotationEffect(.degrees(operationExpanded ? 90 : 0))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(
                            operationExpanded
                                ? String(localized: "Hide Git Output")
                                : String(localized: "Show Git Output")
                        )
                        .accessibilityLabel(
                            operationExpanded
                                ? String(localized: "Hide Git Output")
                                : String(localized: "Show Git Output")
                        )
                    }
                    // Always dismissible: a failed operation is never running.
                    Button {
                        operationExpanded = false
                        model.dismissOperation()
                    } label: {
                        Image(systemName: "xmark")
                            .sidebarFont(size: 8, weight: .semibold)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss Git Error")
                }
                if operationExpanded, !operation.output.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: operation.output)
                            .sidebarFont(size: 9, design: .monospaced)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 96)
                    .accessibilityLabel("Git Output")
                }
            }
            .foregroundStyle(Self.failureColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Self.failureColor.opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    private static let failureColor = Color(red: 0.88, green: 0.42, blue: 0.36)

    /// A sheet rather than an inline field: the panel is narrow, a branch name
    /// is not, and the inline row pushed the whole change list down while it
    /// was open.
    private func presentCreateBranchDialog() {
        guard !model.isBusy else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Create New Branch")
        alert.informativeText = String(localized: "Enter a name for the new branch.")

        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Branch name")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        let create = alert.addButton(withTitle: String(localized: "Create"))
        create.keyEquivalent = "\r"
        create.isEnabled = false
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        let validator = NonemptyTextFieldValidator(button: create)
        field.delegate = validator
        alert.window.initialFirstResponder = field

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            _ = validator // Keep the field's delegate alive until the sheet closes.
            guard response == .alertFirstButtonReturn else { return }
            performOperation(.branchMenu) {
                model.createBranch(named: field.stringValue)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    // MARK: Operation progress

    /// Runs a Git operation and remembers which control asked for it, so that
    /// control shows the progress instead of a banner elsewhere in the panel.
    private func performOperation(_ trigger: OperationTrigger, _ action: () -> Void) {
        operationTrigger = trigger
        action()
    }

    private func operationIsLoading(_ trigger: OperationTrigger) -> Bool {
        model.isBusy && operationTrigger == trigger
    }

    private func operationProgressView() -> some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(
                "",
                text: $commitMessage,
                prompt: Text(commitFieldPlaceholder).foregroundStyle(.tertiary),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .sidebarFont(size: 11.5)
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    performPrimaryAction()
                    return .handled
                }

            // With nothing staged and a sync waiting, Commit is a dead button
            // above the one action there is to take. Drop it and let Sync lead.
            if !showSyncButton || canCommit(includeAll: false) {
                HStack(spacing: 4) {
                    actionButton(
                        icon: "checkmark",
                        title: commitButtonTitle,
                        enabled: canCommit(includeAll: false),
                        help: String(localized: "Commit staged changes (⌘Return)"),
                        loading: operationIsLoading(.primaryAction),
                        action: performPrimaryAction
                    )
                    commitMenu
                }
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy,
                    help: String(localized: "Pull remote commits, then push local ones"),
                    loading: operationIsLoading(.syncButton)
                ) {
                    performOperation(.syncButton, model.syncChanges)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var commitMenu: some View {
        Menu {
            Button("Commit Staged") { performCommit(includeAll: false) }
                .disabled(!canCommit(includeAll: false))
            Button("Stage All & Commit") { performCommit(includeAll: true) }
                .disabled(!canCommit(includeAll: true))
            Divider()
            Button("Amend Last Commit") { performCommit(includeAll: false, amend: true) }
                .disabled(!canAmend(includeAll: false))
            Button("Stage All & Amend") { performCommit(includeAll: true, amend: true) }
                .disabled(!canAmend(includeAll: true))
        } label: {
            ZStack {
                Image(systemName: "chevron.down")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.commitMenu) ? 0 : 1)
                if operationIsLoading(.commitMenu) {
                    operationProgressView()
                }
            }
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Commit Options")
        .accessibilityLabel("Commit Options")
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, help: String,
        loading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Image(systemName: icon)
                        .sidebarFont(size: 10, weight: .semibold)
                        .opacity(loading ? 0 : 1)
                    if loading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                            .tint(.white)
                    }
                }
                Text(title)
                    .sidebarFont(size: 11, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.accent).opacity(enabled ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }

    private var commitFieldPlaceholder: String {
        if model.stagedEntries.isEmpty {
            return model.recentCommits.isEmpty
                ? String(localized: "Message (stage changes to use ⌘⏎)")
                : String(localized: "Message (stage changes to use ⌘⏎, or choose Amend)")
        }
        if let branch = model.branch {
            return String(
                localized: "Message (⌘⏎ to commit on “\(branch)”)",
                comment: "Commit message placeholder. The placeholder is the current branch name."
            )
        }
        return String(localized: "Message (⌘⏎ to commit)")
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = String(localized: "Sync Changes")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        guard !model.stagedEntries.isEmpty else {
            return String(localized: "Commit Staged")
        }
        return String(
            localized: "Commit \(model.stagedEntries.count) Staged Files",
            comment: "Commit button title. The placeholder is the number of staged files."
        )
    }

    private func canCommit(includeAll: Bool) -> Bool {
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false, trigger: .primaryAction)
    }

    private func performCommit(
        includeAll: Bool, amend: Bool = false,
        trigger: OperationTrigger = .commitMenu
    ) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        performOperation(trigger) {
            model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
                if success, commitMessage == submittedMessage { commitMessage = "" }
            }
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                TextField("Filter changed files", text: $filterText)
                    .textFieldStyle(.plain)
                    .sidebarFont(size: 11)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .sidebarFont(size: 10)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Filter")
                    .accessibilityLabel("Clear Git Filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: Change list

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.totalChangeCount == 0 {
                    cleanState
                } else if visibleChangeCount == 0 {
                    inlinePlaceholder(
                        icon: "line.3.horizontal.decrease",
                        text: String(localized: "No changed files match “\(filterText)”")
                    )
                }
                if !filteredMergeEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "MERGE CHANGES"),
                        count: filteredMergeEntries.count,
                        isCollapsed: $mergeCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !mergeCollapsed {
                        ForEach(filteredMergeEntries, id: \.mergeRowID) { entry in
                            row(entry, status: "U", kind: .merge)
                        }
                    }
                }
                if !filteredStagedEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "STAGED CHANGES"),
                        count: filteredStagedEntries.count,
                        isCollapsed: $stagedCollapsed,
                        actions: filterText.isEmpty && model.isEditable ? [
                            .init(
                                systemImage: "minus",
                                help: String(localized: "Unstage All Changes")
                            ) {
                                performOperation(.unstageAll, model.unstageAll)
                            }
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !stagedCollapsed {
                        ForEach(filteredStagedEntries, id: \.stagedRowID) { entry in
                            row(entry, status: entry.staged, kind: .staged)
                        }
                    }
                }
                if !filteredChangedEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "CHANGES"),
                        count: filteredChangedEntries.count,
                        isCollapsed: $changesCollapsed,
                        actions: filterText.isEmpty && model.isEditable ? [
                            .init(
                                systemImage: "arrow.uturn.backward",
                                help: String(localized: "Discard All Changes")
                            ) {
                                requestDiscardAll()
                            },
                            .init(
                                systemImage: "plus",
                                help: String(localized: "Stage All Changes")
                            ) {
                                performOperation(.stageAll, model.stageAll)
                            },
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !changesCollapsed {
                        ForEach(filteredChangedEntries, id: \.changedRowID) { entry in
                            row(entry, status: entry.unstaged, kind: .unstaged)
                        }
                    }
                }
                if filterText.isEmpty, !model.recentCommits.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "RECENT COMMITS"),
                        count: model.recentCommits.count,
                        isCollapsed: $historyCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !historyCollapsed {
                        ForEach(model.recentCommits) { commit in
                            GitCommitRow(commit: commit) { file in
                                openCommitFile(commit, file)
                            }
                        }
                        if model.hasMoreRecentCommits {
                            showMoreCommitsRow
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private var visibleChangeCount: Int {
        filteredMergeEntries.count + filteredStagedEntries.count + filteredChangedEntries.count
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    /// Loads the next page of history. Deliberately a button rather than
    /// loading on scroll: each page is a Git process, and a history nobody is
    /// reading should not keep starting them.
    private var showMoreCommitsRow: some View {
        Button {
            model.loadMoreCommits()
        } label: {
            HStack(spacing: 6) {
                if model.isLoadingMoreCommits {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "ellipsis")
                        .sidebarFont(size: 9, weight: .semibold)
                        .frame(width: 12)
                }
                Text(model.isLoadingMoreCommits ? "Loading…" : "Show More")
                    .sidebarFont(size: 10.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingMoreCommits || model.isBusy)
    }

    private var cleanState: some View {
        inlinePlaceholder(
            icon: model.ahead > 0 || model.behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            text: model.ahead > 0 || model.behind > 0
                ? String(localized: "Working tree clean, sync is pending")
                : String(localized: "Working tree clean")
        )
    }

    private func row(
        _ entry: GitStatusModel.Entry, status: Character, kind: GitEntryRow.Kind
    ) -> some View {
        GitEntryRow(
            entry: entry,
            status: status,
            kind: kind,
            disabled: model.isBusy,
            // A remote repository is shown, not changed, so the row offers
            // nothing that writes — the same shape the remote file tree takes.
            isEditable: model.isEditable,
            remoteHost: model.remoteHost,
            openDiff: {
                guard model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: { openIfPossible(entry) },
            openToSide: { openIfPossible(entry, toSide: true) },
            stage: {
                performOperation(.entry(path: entry.path, operation: .stage)) {
                    model.stage(entry)
                }
            },
            unstage: {
                performOperation(.entry(path: entry.path, operation: .unstage)) {
                    model.unstage(entry)
                }
            },
            discard: { pendingDiscard = makePendingDiscard(entry) },
            absolutePath: model.absolutePath(for: entry),
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { session.sendCommand(shellQuoted(model.absolutePath(for: entry)) + " ") }
            }
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        // A remote path names a file on the other machine, and the tab reads it
        // back over the same connection; asking this machine whether it exists
        // would be a question about a different file.
        guard !model.isEditable || FileManager.default.fileExists(atPath: path) else {
            return
        }
        if toSide {
            openToSide(path)
        } else {
            openFile(path)
        }
    }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        if entry.isUntracked {
            return String(
                localized: "Delete \(entry.fileName)? Its contents will move to the Trash.",
                comment: "Discard confirmation. The placeholder is an untracked file name."
            )
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return String(
                localized: "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored.",
                comment: "Rename discard confirmation. The placeholders are the new and old file names."
            )
        }
        if entry.isWorktreeCopy {
            return String(
                localized: "Discard this copy? \(entry.fileName) will move to the Trash.",
                comment: "Copy discard confirmation. The placeholder is a file name."
            )
        }
        return String(
            localized: "Discard changes in \(entry.fileName)?",
            comment: "Discard confirmation. The placeholder is a file name."
        )
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return String(localized: "Discard Changes") }
        if entry.isUntracked || entry.isWorktreeCopy {
            return String(localized: "Move to Trash")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename") }
        return String(localized: "Discard Changes")
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return PendingDiscard(
            entry: entry,
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, fileFingerprint(at: absolutePath(path, for: entry)))
            }),
            branch: model.branch,
            headOID: model.headOID
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry)
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func requestDiscardAll() {
        pendingDiscardAll = model.changedEntries.map(makePendingDiscard)
        confirmDiscardAll = !pendingDiscardAll.isEmpty
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .sidebarFont(size: 11)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .sidebarFont(size: 18, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .sidebarFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text(model.isSearchingRemoteLoginDirectory
                     ? String(localized: "Can’t Tell Where This Terminal Is")
                     : String(localized: "No Git Repository"))
                    .sidebarFont(size: 11.5, weight: .medium)
                Text(notRepositoryDetail)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if model.isEditable {
                Button("Initialize Repository") {
                    performOperation(.initializeRepository) {
                        model.initializeRepository()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(nsColor: Theme.accent))
                .disabled(model.rootPath.isEmpty || model.isBusy)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    /// Why the panel has nothing to show.
    ///
    /// The remote login-directory case gets its own wording because "no
    /// repository" would be a claim about the wrong directory: the host could
    /// not say where this terminal is, so Terminal looked where an ssh command
    /// lands rather than where the user actually is.
    private var notRepositoryDetail: String {
        if model.isSearchingRemoteLoginDirectory {
            return String(
                localized: "\(model.remoteHost ?? "") couldn’t say which directory this terminal is in — a shell inside screen or tmux can’t be followed — so Terminal looked in \(model.rootPath), where an ssh command lands. Open the repository’s directory in a new terminal to work on it here.",
                comment: "Git panel empty state on a remote host whose working directory could not be established. The placeholders are a hostname and the directory that was searched."
            )
        }
        if !model.isEditable {
            return String(
                localized: "\(model.displayPath) is not in a repository.",
                comment: "Git panel empty state for a remote directory outside any repository. The placeholder is a host-qualified path."
            )
        }
        return String(localized: "Initialize the terminal’s current directory to start tracking changes.")
    }

    private func statusFailure(_ message: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            VStack(spacing: 3) {
                Text("Git Status Unavailable")
                    .sidebarFont(size: 11.5, weight: .medium)
                Text(verbatim: message)
                    .sidebarFont(size: 10, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            Button("Retry") { model.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isResolvingInitialStatus)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, label: String) -> some View {
        Text(verbatim: text)
            .sidebarFont(size: 10, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel(label)
    }

    private func copyChangedPaths() {
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        filterText = ""
        showFilter = false
        operationExpanded = false
        pendingDiscard = nil
        pendingDiscardAll = []
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = true
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct GitSectionHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        let perform: () -> Void
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]
    var actionsDisabled = false
    /// When set, a small "?" after the title opens this in a popover.
    var helpText: String?

    @State private var isHovering = false
    @State private var isShowingHelp = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .sidebarFont(size: 7, weight: .semibold)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .sidebarFont(size: 9.5, weight: .medium)
                }
                .foregroundStyle(Color.secondary.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if let helpText {
                Button {
                    isShowingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .sidebarFont(size: 9)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                    Text(helpText)
                        .sidebarFont(size: 11)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(12)
                }
            }

            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(systemName: action.systemImage)
                        .sidebarFont(size: 9, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .disabled(actionsDisabled)
                .opacity(actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55))
                .help(action.help)
                .accessibilityLabel(action.help)
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text("\(count)")
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.help, action: action.perform)
                    .disabled(actionsDisabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

/// A commit in the history, which opens to show what it changed. Each file
/// inside opens that commit against its parent, so a change can be read
/// without leaving for a terminal.
/// Keeps an alert's default button disabled until its field has something in
/// it. `NSAlert` has no notion of a required field, and a Create button that
/// runs `git branch ""` is a failure banner waiting to happen.
private final class NonemptyTextFieldValidator: NSObject, NSTextFieldDelegate {
    private let button: NSButton

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button.isEnabled = !field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

private struct GitCommitRow: View {
    @ObservedObject private var themeChanges = Theme.changes
    let commit: GitStatusModel.RecentCommit
    let openFile: (GitStatusModel.RecentCommit.FileChange) -> Void

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if commit.files.isEmpty {
                    // A merge carries no file rows against its first parent.
                    Text("No file changes")
                        .sidebarFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                        .padding(.vertical, 3)
                } else {
                    ForEach(commit.files) { file in
                        fileRow(file)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(commit.subject)
                            .sidebarFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ForEach(commit.references, id: \.self) { reference in
                            referenceBadge(reference)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(commit.shortHash)
                            .sidebarFont(size: 9.5, design: .monospaced)
                            .foregroundStyle(Color(nsColor: Theme.accent).opacity(0.85))
                        Text("·")
                        Text(commit.author)
                        Text("·")
                        Text(commit.relativeDate)
                        if !commit.files.isEmpty {
                            Text("·")
                            Text("\(commit.files.count) files")
                        }
                    }
                    .sidebarFont(size: 9.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Commit Hash") { copy(commit.hash) }
            Button("Copy Commit Message") { copy(commit.subject) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(commit.subject), \(commit.shortHash), by \(commit.author), \(commit.relativeDate)"
        )
        .accessibilityHint(isExpanded ? "Hide changed files" : "Show changed files")
    }

    /// A branch or tag pointing at this commit. `--decorate` writes the
    /// current branch as "HEAD -> main"; only the name is worth the space.
    private func referenceBadge(_ reference: String) -> some View {
        let name = reference.contains("->")
            ? String(reference.split(separator: ">").last ?? "").trimmingCharacters(in: .whitespaces)
            : reference
        return Text(name)
            .sidebarFont(size: 8.5, weight: .medium)
            .foregroundStyle(Color(nsColor: Theme.accent))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color(nsColor: Theme.accent).opacity(0.14))
            )
            .fixedSize()
    }

    private func fileRow(_ file: GitStatusModel.RecentCommit.FileChange) -> some View {
        Button {
            openFile(file)
        } label: {
            HStack(spacing: 7) {
                Text(String(file.status))
                    .sidebarFont(size: 10, weight: .bold, design: .monospaced)
                    .foregroundStyle(gitStatusColor(file.status))
                    .frame(width: 12)
                MaterialFileIconView(
                    path: file.path, size: 13, opacity: file.status == "D" ? 0.6 : 1
                )
                Text(file.fileName)
                    .sidebarFont(size: 11)
                    .foregroundStyle(.secondary)
                    .strikethrough(file.status == "D")
                    .lineLimit(1)
                    .layoutPriority(1)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .sidebarFont(size: 9.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.originalPath.map { String(localized: "Renamed from \($0)") }
            ?? String(localized: "Open this file as it changed in \(commit.shortHash)"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct GitEntryRow: View {
    enum Kind {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let status: Character
    let kind: Kind
    let disabled: Bool
    /// False for a repository on another machine, where the row shows changes
    /// but offers nothing that would write to them.
    let isEditable: Bool
    /// The host the file is on, when it is not this machine's; used for the
    /// `host:/path` form that stays meaningful off that machine.
    let remoteHost: String?
    let openDiff: () -> Void
    let openFile: () -> Void
    let openToSide: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String
    let copyRelativePath: () -> Void
    let insertInTerminal: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: openDiff) {
                HStack(spacing: 7) {
                    Text(String(status))
                        .sidebarFont(size: 10, weight: .bold, design: .monospaced)
                        .foregroundStyle(statusColor)
                        .frame(width: 12)
                    MaterialFileIconView(
                        path: absolutePath,
                        size: 13,
                        opacity: status == "D" ? 0.6 : 1
                    )
                    Text(entry.fileName)
                        .sidebarFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .strikethrough(status == "D")
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isHovering && !isFocused {
                        Text(entry.directory)
                            .sidebarFont(size: 10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel("\(entry.fileName), \(statusName)")
            .accessibilityHint(kind == .merge ? "Opens conflict changes" : "Opens changes")

            if !disabled && isEditable {
                hoverActions
                    .opacity(isHovering || isFocused ? 1 : 0.55)
            }
        }
        // Fixed height so action buttons do not grow the dense file row.
        .frame(minHeight: 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering || isFocused ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { menu }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            switch kind {
            case .merge:
                rowButton(
                    "plus",
                    help: String(localized: "Mark Resolved (Stage)"),
                    action: stage
                )
            case .staged:
                rowButton(
                    "minus",
                    help: String(localized: "Unstage Changes"),
                    action: unstage
                )
            case .unstaged:
                rowButton(
                    "arrow.uturn.backward",
                    help: String(localized: "Discard Changes"),
                    action: discard
                )
                rowButton(
                    "plus",
                    help: String(localized: "Stage Changes"),
                    action: stage
                )
            }
        }
    }

    private func rowButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .sidebarFont(size: 9, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var menu: some View {
        if kind == .merge {
            Button("Open Changes") { openDiff() }
            Button("Open Conflicted File") { openFile() }
        } else {
            Button("Open Changes") { openDiff() }
            Button("Open File") { openFile() }
        }
        Button("Open File to the Side") { openToSide() }
        if isEditable {
            Divider()
            switch kind {
            case .merge:
                Button("Mark Resolved (Stage)") { stage() }
                    .disabled(disabled)
            case .staged:
                Button("Unstage Changes") { unstage() }
                    .disabled(disabled)
            case .unstaged:
                Button("Stage Changes") { stage() }
                    .disabled(disabled)
                Button(destructiveMenuTitle) { discard() }
                    .disabled(disabled)
            }
        }
        Divider()
        // Left out for a remote row: the path names a file on the other
        // machine, and handing it to Finder would reveal whatever happens to
        // sit at the same path here.
        if isEditable {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: absolutePath)]
                )
            }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        if let remoteHost {
            Button("Copy Path with Host") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(remoteHost):\(absolutePath)", forType: .string)
            }
        }
        Button("Copy Relative Path") { copyRelativePath() }
        if let insertInTerminal {
            Button("Insert Absolute Path in Terminal") { insertInTerminal() }
        }
    }

    private var statusName: String {
        switch status {
        case "M": return String(localized: "Modified")
        case "A": return String(localized: "Added")
        case "?": return String(localized: "Untracked")
        case "D": return String(localized: "Deleted")
        case "R": return String(localized: "Renamed")
        case "C": return String(localized: "Copied")
        case "U": return String(localized: "Conflict")
        default: return String(localized: "Changed")
        }
    }

    private var destructiveMenuTitle: String {
        if entry.isUntracked || entry.isWorktreeCopy {
            return String(localized: "Move to Trash…")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename…") }
        return String(localized: "Discard Changes…")
    }

    private var statusColor: Color { gitStatusColor(status) }
}

/// The colour a porcelain status letter is shown in, wherever one appears —
/// the changed-file rows and the files inside a commit read the same way.
func gitStatusColor(_ status: Character) -> Color {
    switch status {
    case "M": Color(red: 0.82, green: 0.60, blue: 0.13)
    case "A", "?": Color(red: 0.25, green: 0.73, blue: 0.31)
    case "D": Color(red: 1.0, green: 0.48, blue: 0.45)
    case "R", "C": Color(red: 0.35, green: 0.65, blue: 1.0)
    case "U": Color(red: 0.74, green: 0.55, blue: 1.0)
    default: .secondary
    }
}

// MARK: - Info panel

/// Session dashboard: working directory (with reveal/open/copy actions),
/// processes running under the shell, and ports they are listening on.
private struct InfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    @ObservedObject private var themeChanges = Theme.changes
    let session: TerminalSession?

    @State private var currentDirectoryCollapsed = false
    @State private var projectDirectoryCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private static let vsCodeURL = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    currentDirectorySection
                    projectDirectorySection
                    processesSection
                    portsSection
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .sidebarFont(size: 11, weight: .medium)
                .foregroundStyle(Color(nsColor: Theme.accent))
            PanelHeader(
                title: model.shellName.isEmpty ? String(localized: "Session") : model.shellName,
                subtitle: model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
            )
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .sidebarFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Directories

    /// Hidden while the shell sits at the project root — it earns its row
    /// once the cwd diverges from the directory the panels anchor to.
    @ViewBuilder
    private var currentDirectorySection: some View {
        if model.rootPath != model.projectRootPath {
            GitSectionHeader(
                title: String(localized: "CURRENT DIRECTORY"), count: 0,
                isCollapsed: $currentDirectoryCollapsed, actions: []
            )
            if !currentDirectoryCollapsed {
                directoryGroup(path: model.rootPath)
            }
        }
    }

    @ViewBuilder
    private var projectDirectorySection: some View {
        if !model.projectRootPath.isEmpty {
            GitSectionHeader(
                title: projectDirectoryTitle,
                count: 0,
                isCollapsed: $projectDirectoryCollapsed, actions: [],
                helpText: String(localized: "Files and Git anchor to this directory. When automatic, it follows the closest Git repository containing the shell’s current directory, or the one the terminal’s foreground job moved to — a coding agent that switched to its own worktree. A directory set manually from the project’s context menu is always used as-is.")
            )
            if !projectDirectoryCollapsed {
                directoryGroup(path: model.projectRootPath)
            }
        }
    }

    /// Names the rule behind the project directory: a root taken from the
    /// foreground job says so rather than passing itself off as the shell's
    /// own repository.
    private var projectDirectoryTitle: String {
        switch model.projectRootSource {
        case .pinned:
            return String(localized: "PROJECT DIRECTORY")
        case .shell:
            return String(localized: "PROJECT DIRECTORY (AUTO)")
        case .foreground(let isWorktree):
            return isWorktree
                ? String(localized: "PROJECT DIRECTORY (WORKTREE)")
                : String(localized: "PROJECT DIRECTORY (JOB)")
        }
    }

    /// Path line plus Finder / VS Code / Copy actions, shared by both
    /// directory sections.
    private func directoryGroup(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: path)
                .sidebarFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
                .contextMenu {
                    Button("Copy Path") { copyPath(path) }
                }

            HStack(spacing: 4) {
                actionButton("Finder", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)]
                    )
                }
                if let vsCode = Self.vsCodeURL {
                    actionButton("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: path)],
                            withApplicationAt: vsCode,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
                actionButton(String(localized: "Copy"), systemImage: "doc.on.doc") {
                    copyPath(path)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func actionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .sidebarFont(size: 9, weight: .medium)
                Text(verbatim: title)
                    .sidebarFont(size: 10, weight: .medium)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(systemImage == "doc.on.doc"
            ? String(localized: "Copy Path")
            : String(localized: "Open in \(title)"))
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        GitSectionHeader(
            title: String(localized: "PROCESSES"),
            count: model.processes.count,
            isCollapsed: $processesCollapsed,
            actions: []
        )
        if !processesCollapsed {
            if model.processes.isEmpty {
                emptyRow(String(localized: "No running processes"))
            } else {
                ForEach(model.processes) { process in
                    InfoProcessRow(process: process) { force in
                        model.kill(process.pid, force: force)
                    }
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private var portsSection: some View {
        GitSectionHeader(
            title: String(localized: "PORTS"),
            count: model.ports.count,
            isCollapsed: $portsCollapsed,
            actions: []
        )
        if !portsCollapsed {
            if model.ports.isEmpty {
                emptyRow(String(localized: "No listening ports"))
            } else {
                ForEach(model.ports) { port in
                    InfoPortRow(port: port) { force in
                        model.kill(port.pid, force: force)
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .sidebarFont(size: 11)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct InfoProcessRow: View {
    let process: SessionInfoModel.ProcessItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                .frame(width: 5, height: 5)
            Text(process.name)
                .sidebarFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .sidebarFont(size: 10, design: .monospaced)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .sidebarFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Terminate Process")
            } else {
                Text("\(process.cpu, format: .number.precision(.fractionLength(0)))% · \(process.memoryLabel)")
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // Fixed height so the taller hover button doesn't grow the row.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Terminate") { kill(false) }
            Button("Force Kill") { kill(true) }
            Divider()
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
            Button("Copy Executable Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executable, forType: .string)
            }
        }
    }
}

private struct InfoPortRow: View {
    let port: SessionInfoModel.PortItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    private var urlString: String { "http://localhost:\(port.port)" }

    var body: some View {
        Button {
            if let url = port.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(String(port.port))
                    .sidebarFont(size: 11.5, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .sidebarFont(size: 9, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            // Fixed height to match the other sidebar rows.
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Open \(urlString)")
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") {
                if let url = port.url {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            Divider()
            Button("Kill Process (\(port.processName))") { kill(false) }
        }
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
