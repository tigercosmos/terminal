//
//  ComparePanelView.swift
//  terminal
//

import AppKit
import SwiftUI
import TerminalCore

/// Compare panel: pick a branch or commit, see every file in the working tree
/// that differs from it, and open any of them side by side with the file still
/// editable.
///
/// The Git panel answers "what have I changed since my last commit?". This one
/// answers "how does my tree differ from that branch, or from that commit last
/// Tuesday?" — a question the index cannot express.
struct ComparePanel: View {
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject var model: GitCompareModel
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openCompare: (
        _ entry: GitCompareModel.Entry, _ target: GitCompareModel.Target
    ) -> Void

    @State private var filter = CompareFilter()
    @State private var showFilter = false
    @State private var isPicking = false
    @State private var pickerQuery = ""
    /// The row being confirmed, with the file as it was when the sheet opened.
    @State private var pendingRevert: (
        entry: GitCompareModel.Entry, fingerprint: GitCompareModel.FileFingerprint
    )?
    @State private var listCollapsed = false
    @FocusState private var pickerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            errorBanner

            if let statusError = model.statusError {
                placeholder(icon: "exclamationmark.triangle", text: statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialList {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…"))
                } else {
                    placeholder(
                        icon: "arrow.triangle.branch",
                        text: String(localized: "Open a Git repository to compare against a branch or commit.")
                    )
                }
            } else {
                if isPicking {
                    targetPicker
                } else if let target = model.target {
                    filterBar
                    fileList(target)
                } else {
                    chooseTargetPrompt
                }
            }
        }
        .confirmationDialog(
            revertTitle(for: pendingRevert?.entry),
            isPresented: Binding(
                get: { pendingRevert != nil },
                set: { if !$0 { pendingRevert = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(revertActionTitle(for: pendingRevert?.entry), role: .destructive) {
                if let pendingRevert {
                    model.revert(pendingRevert.entry, confirmedAs: pendingRevert.fingerprint)
                }
                pendingRevert = nil
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across a
            // change of repository.
            pendingRevert = nil
            closePicker()
        }
        .onChange(of: filter) {
            model.applySearch(filter)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo, model.hasTarget {
                targetMenu
            } else {
                Image(systemName: "arrow.left.arrow.right")
                    .sidebarFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(title: String(localized: "Compare"), subtitle: model.displayPath)
            }
            if model.isBusy || model.isResolvingInitialList || model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(
                        model.isBusy
                            ? String(localized: "Reverting a file")
                            : String(localized: "Refreshing the comparison")
                    )
            }
            if isPicking {
                headerButton(
                    "xmark",
                    help: String(localized: "Cancel"),
                    disabled: false,
                    action: closePicker
                )
            } else if model.isRepo, model.hasTarget {
                headerButton(
                    "line.3.horizontal.decrease",
                    help: String(localized: "Filter Compared Files"),
                    disabled: false
                ) {
                    showFilter.toggle()
                    if !showFilter { filter = CompareFilter() }
                }
                headerButton(
                    "arrow.clockwise",
                    help: String(localized: "Refresh Comparison"),
                    disabled: model.isBusy || model.isResolvingInitialList
                ) {
                    model.refresh()
                }
                headerButton(
                    "xmark.circle",
                    help: String(localized: "Clear Comparison Target"),
                    disabled: model.isBusy
                ) {
                    model.clearTarget()
                    filter = CompareFilter()
                    showFilter = false
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
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
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError ?? model.targetError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .sidebarFont(size: 9)
                Text(message)
                    .sidebarFont(size: 10.5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .sidebarFont(size: 9, weight: .medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045))
        }
    }

    // MARK: Target

    private var chooseTargetPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare against a branch or commit to see every file that differs — and keep editing while you read.")
                .sidebarFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openPicker()
            } label: {
                HStack(spacing: 4) {
                    Text("Choose Target…")
                    Image(systemName: "chevron.right")
                        .sidebarFont(size: 7, weight: .semibold)
                }
                .sidebarFont(size: 11, weight: .medium)
                .foregroundStyle(Color(nsColor: Theme.accent))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: Theme.accent).opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    /// The header's title, and the control that opens the picker. Same shape
    /// as the Git panel's branch menu, so the two panels read as one family.
    private var targetMenu: some View {
        Button {
            openPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .sidebarFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(
                    title: model.target?.displayName ?? String(localized: "Compare"),
                    subtitle: model.target?.tracksTip == true
                        ? String(localized: "follows the branch tip")
                        : String(localized: "pinned to this commit")
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isBusy)
        .help(String(localized: "Change what the working tree is compared against"))
    }

    private func branchButton(_ branch: String) -> some View {
        Button {
            model.setTarget(branch, kind: .branch)
        } label: {
            if branch == model.target?.name {
                Label(branch, systemImage: "checkmark")
            } else {
                Text(branch)
            }
        }
    }

    // MARK: Target picker

    /// One thing the working tree can be compared against.
    fileprivate enum TargetChoice: Identifiable {
        case branch(String)
        case commit(GitStatusModel.RecentCommit)
        /// Whatever was typed, when it matches nothing in the lists — a tag, a
        /// SHA, `HEAD~2`. Resolved when chosen, and reported if it does not.
        case revision(String)

        var id: String {
            switch self {
            case .branch(let name): return "b:" + name
            case .commit(let commit): return "c:" + commit.hash
            case .revision(let text): return "r:" + text
            }
        }
    }

    /// Choosing a target is a search, not a menu: a repository has more
    /// branches and commits than a menu can show, and the thing being looked
    /// for is usually known by name. Typing filters branches and commits
    /// together, and anything Git understands can be entered directly.
    private var targetPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                TextField("Branch, tag, SHA, or HEAD~2", text: $pickerQuery)
                    .textFieldStyle(.plain)
                    .sidebarFont(size: 11)
                    .focused($pickerFocused)
                    .onSubmit {
                        if let first = pickerChoices.first { choose(first) }
                    }
                if !pickerQuery.isEmpty {
                    // Same glyph, same place, same meaning as the Git panel's
                    // filter field. It used to dismiss the whole picker, which
                    // lost your place when you only wanted to retype a name.
                    Button {
                        pickerQuery = ""
                        pickerFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .sidebarFont(size: 10)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear"))
                    .accessibilityLabel("Clear the search")
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if pickerChoices.isEmpty {
                        inlinePlaceholder(
                            icon: "magnifyingglass",
                            text: String(localized: "No branch or commit matches")
                        )
                    }
                    ForEach(pickerChoices) { choice in
                        TargetChoiceRow(
                            choice: choice,
                            isCurrent: isCurrentTarget(choice),
                            choose: { choose(choice) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        // Escape backs out, the way it does from any other search field.
        .onExitCommand(perform: closePicker)
    }

    /// Branches first — a branch is the usual answer and tracks its tip — then
    /// commits, then whatever was typed if it matched neither.
    private var pickerChoices: [TargetChoice] {
        let query = pickerQuery.trimmingCharacters(in: .whitespaces)
        let branches = (model.localBranches + model.remoteBranches).filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }
        let commits = model.recentCommits.filter {
            query.isEmpty
                || $0.subject.localizedCaseInsensitiveContains(query)
                || $0.shortHash.localizedCaseInsensitiveContains(query)
                || $0.author.localizedCaseInsensitiveContains(query)
        }
        var choices = branches.map(TargetChoice.branch) + commits.map(TargetChoice.commit)
        if !query.isEmpty, !branches.contains(query) {
            choices.append(.revision(query))
        }
        return choices
    }

    private func isCurrentTarget(_ choice: TargetChoice) -> Bool {
        switch choice {
        case .branch(let name): return model.target?.name == name
        case .commit(let commit): return model.target?.oid == commit.hash
        case .revision: return false
        }
    }

    private func openPicker() {
        pickerQuery = ""
        isPicking = true
        DispatchQueue.main.async { pickerFocused = true }
    }

    private func closePicker() {
        isPicking = false
        pickerQuery = ""
    }

    /// A branch keeps tip-tracking semantics however it was picked, so typing
    /// `main` behaves the same as choosing it from the list; everything else is
    /// pinned to the commit it resolves to.
    private func choose(_ choice: TargetChoice) {
        switch choice {
        case .branch(let name):
            model.setTarget(name, kind: .branch)
        case .commit(let commit):
            model.setTarget(commit.hash, kind: .revision)
        case .revision(let text):
            let isBranch = model.localBranches.contains(text)
                || model.remoteBranches.contains(text)
            model.setTarget(text, kind: isBranch ? .branch : .revision)
        }
        closePicker()
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .sidebarFont(size: 10)
                        .foregroundStyle(.tertiary)
                    TextField("Search compared files", text: $filter.query)
                        .textFieldStyle(.plain)
                        .sidebarFont(size: 11)
                    if !filter.query.isEmpty {
                        Button { filter.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .sidebarFont(size: 10)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Clear"))
                        .accessibilityLabel("Clear the search")
                    }
                    HStack(spacing: 1) {
                        toggle("textformat", on: $filter.matchCase, help: String(localized: "Match Case"))
                        toggle("textformat.abc.dottedunderline", on: $filter.wholeWord, help: String(localized: "Match Whole Word"))
                        toggle("asterisk", on: $filter.useRegex, help: String(localized: "Use Regular Expression"))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.045))
                )

                if let searchError = model.searchError {
                    Text(searchError)
                        .sidebarFont(size: 10)
                        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 0) {
                    globField(String(localized: "include"), text: $filter.include)
                    Rectangle()
                        .fill(Color(nsColor: Theme.divider))
                        .frame(width: 1, height: 12)
                    globField(String(localized: "exclude"), text: $filter.exclude)
                }
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.03))
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private func globField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .sidebarFont(size: 10.5)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .help(String(localized: "Comma-separated globs, e.g. *.swift, terminal/, **/*Test*"))
    }

    private func toggle(
        _ systemImage: String, on binding: Binding<Bool>, help: String
    ) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            Image(systemName: systemImage)
                .sidebarFont(size: 9, weight: .medium)
                .foregroundStyle(binding.wrappedValue ? AnyShapeStyle(Color(nsColor: Theme.accent)) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(binding.wrappedValue ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(binding.wrappedValue ? "On" : "Off")
    }

    // MARK: File list

    private func fileList(_ target: GitCompareModel.Target) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.targetError != nil {
                    // The banner above already explains it; do not also claim
                    // the tree matches the target.
                    EmptyView()
                } else if model.entries.isEmpty {
                    inlinePlaceholder(
                        icon: "checkmark.circle",
                        text: model.isResolvingInitialList
                            ? String(localized: "Comparing…")
                            : String(localized: "Your tree matches \(target.displayName)")
                    )
                } else if visibleEntries.isEmpty {
                    inlinePlaceholder(
                        icon: "line.3.horizontal.decrease",
                        text: String(localized: "No compared files match the filter")
                    )
                }
                if !visibleEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "CHANGED FILES"),
                        count: visibleEntries.count,
                        isCollapsed: $listCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                }
                ForEach(listCollapsed ? [] : visibleEntries) { entry in
                    CompareEntryRow(
                        entry: entry,
                        // Nearly every row in a comparison shares one directory,
                        // so printing it on all of them truncated it to noise
                        // ("…minal") while saying nothing. It appears only when
                        // two visible files share a name and it tells them apart.
                        showsDirectory: ambiguousNames.contains(entry.fileName),
                        disabled: model.isBusy,
                        // A remote comparison is read, not reverted: what a
                        // revert reaches for — the Trash, for a file the target
                        // does not have — belongs to this Mac.
                        isEditable: model.isEditable,
                        remoteHost: model.remoteHost,
                        absolutePath: model.absolutePath(for: entry),
                        openCompare: { openCompare(entry, target) },
                        openFile: { openFile(model.absolutePath(for: entry)) },
                        openToSide: { openToSide(model.absolutePath(for: entry)) },
                        revert: {
                            pendingRevert = (entry, model.fingerprint(for: entry))
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    /// File names that appear on more than one visible row, and so need their
    /// directory shown to be told apart.
    private var ambiguousNames: Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for entry in visibleEntries where !seen.insert(entry.fileName).inserted {
            repeated.insert(entry.fileName)
        }
        return repeated
    }

    /// Globs are cheap and run here; the content search runs in the model,
    /// which reads files off the main actor and publishes the paths that hit.
    private var visibleEntries: [GitCompareModel.Entry] {
        let include = CompareFilterCompiler.GlobMatcher(filter.include)
        let exclude = CompareFilterCompiler.GlobMatcher(filter.exclude)
        let matches = filter.hasQuery ? model.searchMatches : nil
        return model.entries.filter { entry in
            if let include, !include.matches(entry.path) { return false }
            if let exclude, exclude.matches(entry.path) { return false }
            if let matches, !matches.contains(entry.path) { return false }
            return true
        }
    }

    // MARK: Revert confirmation

    private func revertTitle(for entry: GitCompareModel.Entry?) -> String {
        guard let entry, let target = model.target else { return "" }
        if entry.isAddition {
            return String(
                localized: "Move “\(entry.fileName)” to the Trash? It does not exist at \(target.displayName).",
                comment: "Revert confirmation for a file the comparison target does not have."
            )
        }
        return String(
            localized: "Discard your changes to “\(entry.fileName)” and restore it from \(target.displayName)?",
            comment: "Revert confirmation for a file that exists at the comparison target."
        )
    }

    private func revertActionTitle(for entry: GitCompareModel.Entry?) -> String {
        guard let entry else { return String(localized: "Revert") }
        return entry.isAddition
            ? String(localized: "Move to Trash")
            : String(localized: "Restore from Target")
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            Text(text)
                .sidebarFont(size: 11)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .sidebarFont(size: 10)
                .foregroundStyle(.quaternary)
            Text(text)
                .sidebarFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

/// One file that differs from the comparison target.
private struct CompareEntryRow: View {
    let entry: GitCompareModel.Entry
    let showsDirectory: Bool
    let disabled: Bool
    /// False for a repository on another machine, where the row shows what
    /// differs but offers nothing that would write to it.
    let isEditable: Bool
    /// The host the file is on, when it is not this machine's; used for the
    /// `host:/path` form that stays meaningful off that machine.
    let remoteHost: String?
    let absolutePath: String
    let openCompare: () -> Void
    let openFile: () -> Void
    let openToSide: () -> Void
    let revert: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: openCompare) {
                HStack(spacing: 7) {
                    Text(String(entry.status))
                        .sidebarFont(size: 10, weight: .bold, design: .monospaced)
                        .foregroundStyle(statusColor)
                        .frame(width: 12)
                    Text(entry.fileName)
                        .sidebarFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .strikethrough(entry.isDeletion)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if showsDirectory, !isHovering, !isFocused {
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
            // The path always stays reachable even though the row rarely shows it.
            .help(entry.path)
            .accessibilityLabel("\(entry.fileName), \(statusName)")
            .accessibilityHint("Opens the comparison, editable")

            if !disabled && isEditable {
                Button(action: revert) {
                    Image(systemName: "arrow.uturn.backward")
                        .sidebarFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isFocused ? 1 : 0.55)
                .help(String(localized: "Revert to Comparison Target"))
                .accessibilityLabel("Revert to comparison target")
            }
        }
        // Fixed height so the action button does not grow the dense file row.
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

    @ViewBuilder
    private var menu: some View {
        Button("Open Comparison") { openCompare() }
        Button("Open File") { openFile() }
        Button("Open File to the Side") { openToSide() }
        if isEditable {
            Divider()
            Button("Revert to Comparison Target…") { revert() }
                .disabled(disabled)
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
        Button("Copy Relative Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

    private var statusName: String {
        switch entry.status {
        case "M": return String(localized: "Modified")
        case "A": return String(localized: "Added")
        case "?": return String(localized: "Untracked")
        case "D": return String(localized: "Deleted")
        case "R": return String(localized: "Renamed")
        case "C": return String(localized: "Copied")
        case "T": return String(localized: "Type changed")
        default: return String(localized: "Changed")
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case "M": return Color(red: 0.82, green: 0.60, blue: 0.13)
        case "A", "?": return Color(red: 0.25, green: 0.73, blue: 0.31)
        case "D": return Color(red: 1.0, green: 0.48, blue: 0.45)
        case "R", "C": return Color(red: 0.35, green: 0.65, blue: 1.0)
        default: return .secondary
        }
    }
}

/// One branch, commit, or typed revision in the target picker.
private struct TargetChoiceRow: View {
    let choice: ComparePanel.TargetChoice
    let isCurrent: Bool
    let choose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(
                        isCurrent
                            ? AnyShapeStyle(Color(nsColor: Theme.accent))
                            : AnyShapeStyle(.tertiary)
                    )
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .sidebarFont(size: 11.5)
                        .foregroundStyle(
                            isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        // A branch name is told apart by its end, so it keeps
                        // its head and tail; a commit subject reads as a
                        // sentence and is cut at the end like one.
                        .truncationMode(truncation)
                    if let detail {
                        Text(detail)
                            .sidebarFont(size: 9.5)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityText)
    }

    private var truncation: Text.TruncationMode {
        if case .branch = choice { return .middle }
        return .tail
    }

    private var icon: String {
        switch choice {
        case .branch: return "arrow.triangle.branch"
        case .commit: return "circle.fill"
        case .revision: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private var title: String {
        switch choice {
        case .branch(let name): return name
        case .commit(let commit): return commit.subject
        case .revision(let text): return String(localized: "Compare with “\(text)”")
        }
    }

    private var detail: String? {
        switch choice {
        case .branch: return nil
        case .commit(let commit):
            return "\(commit.shortHash) · \(commit.author) · \(commit.relativeDate)"
        case .revision: return String(localized: "tag, SHA, or revision expression")
        }
    }

    private var accessibilityText: String {
        detail.map { "\(title), \($0)" } ?? title
    }
}
