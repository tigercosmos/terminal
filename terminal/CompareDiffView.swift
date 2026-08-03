//
//  CompareDiffView.swift
//  terminal
//

import AppKit
import Combine
import STTextKitPlus
import SwiftUI
// `contentFrame` is where the layout actually places text inside the view, once
// the gutter and the container inset are taken out. Row tinting is drawn in the
// text view's own coordinate space and so needs that origin, and STTextView
// publishes it only to plugins. Terminal vendors STTextView (Vendor/STTextView)
// and builds it from source, so this is an SPI on code that ships in this
// repository rather than on a binary dependency that could move underneath it.
@_spi(Plugins) import STTextView

/// One file compared against a branch or commit, opened as a pane.
///
/// The left column is the file as of the target and is read-only. The right
/// column is the file on disk, live and editable — that is the whole point:
/// read the comparison and fix the code in the same view, then save.
@MainActor
final class CompareTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// The repository the comparison runs in, and the machine it is on.
    let repository: GitDirectory

    /// Absolute repository root, for the path arithmetic the editable column
    /// needs. Still a path on ``repository``'s machine.
    var repoRoot: String { repository.path }

    /// Set for a tab restored from a saved session whose repository was on
    /// another host. Terminal does not open an ssh connection at launch to
    /// read it, so the pane says where the comparison is instead of running
    /// Git against whatever repository sits at the same path here.
    let disconnectedHost: String?

    /// The host this comparison's repository is on, for the session snapshot.
    var remoteHost: String? { repository.host ?? disconnectedHost }
    /// Repo-relative path of the working-tree file — the right column.
    private(set) var path: String
    /// The file's path *at the target* when it was renamed, so the left column
    /// reads the file's own history instead of showing the whole file as new.
    let origPath: String?
    /// The commit the left column reads from. Pinned when the tab opens, so a
    /// branch moving under a comparison cannot silently change what an open
    /// tab is showing; reopening from the panel picks up the new tip.
    let targetOID: String
    /// What to call the target in the header — a branch name, or a revision.
    let targetName: String

    /// The right column. A real `FileTab`, so saving, the dirty indicator, the
    /// external-change conflict prompt, the find bar, and the prompt on closing
    /// with unsaved changes all behave exactly as in an ordinary editor pane.
    let file: FileTab

    @Published private(set) var baseText = ""
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    /// Set when the two sides were too large to align and are shown unlevelled.
    /// Surfaced so an unaligned view is never mistaken for a wrong diff.
    @Published var isUnaligned = false

    private var reloadGeneration: UInt = 0

    init(
        repository: GitDirectory, path: String, origPath: String?,
        targetOID: String, targetName: String, disconnectedFrom host: String? = nil
    ) {
        self.repository = repository
        self.path = path
        self.origPath = origPath
        self.targetOID = targetOID
        self.targetName = targetName
        disconnectedHost = host
        // Reached over the same connection the panel is using, so a comparison
        // against a repository on another machine opens that machine's file
        // rather than whatever sits at the same path here. A remote `FileTab`
        // is read-only, which is what makes the editable column editable only
        // when there is something local to edit.
        file = host.map { FileTab(path: repository.appending(path), disconnectedFrom: $0) }
            ?? FileTab(path: repository.appending(path), remote: repository.remote)
        reload()
    }

    var name: String { (path as NSString).lastPathComponent }
    var title: String { name }

    var shortOID: String { String(targetOID.prefix(7)) }

    /// The file exists at the target but not on disk. The right column is then
    /// legitimately empty rather than unreadable.
    var isDeletedFromWorkingTree: Bool {
        if case .unavailable = file.content {
            // The file tab could not read it, so on a remote host "unavailable"
            // already means the far side had nothing to give; asking the local
            // file system about a remote path would answer about a different
            // machine's file.
            guard repository.isLocal else { return !baseText.isEmpty }
            return !baseText.isEmpty
                && !FileManager.default.fileExists(atPath: repository.appending(path))
        }
        return false
    }

    /// Re-points the tab after the file was renamed on disk, matching
    /// `FileTab.updatePath`. The target side is unaffected: it reads from a
    /// commit, which a rename in the working tree cannot change.
    func updatePath(_ newPath: String) {
        // Matched against `repoRoot` verbatim: `file.path` was built by
        // appending to this exact string, and standardizing it here could
        // rewrite it (a symlinked root, a doubled separator) into a prefix the
        // path no longer starts with.
        let root = repoRoot + "/"
        guard newPath.hasPrefix(root) else { return }
        path = String(newPath.dropFirst(root.count))
        file.updatePath(newPath)
    }

    /// Loads the target side. The working-tree side is the `FileTab`, which
    /// loads and reloads itself.
    func reload() {
        reloadGeneration &+= 1
        if let disconnectedHost {
            isLoading = false
            error = String(
                localized: "This repository is on \(disconnectedHost). Connect to it in a terminal to see the comparison.",
                comment: "Shown in place of a restored comparison whose repository is on a remote host. The placeholder is a hostname."
            )
            return
        }
        let generation = reloadGeneration
        isLoading = true
        error = nil
        let root = repository
        let oid = targetOID
        let oldPath = origPath ?? path

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var failure: String?
                // A path absent at the target yields an empty side, which is
                // the correct "everything here is new" comparison.
                let text = GitFileContent.firstBlob(
                    ["\(oid):\(oldPath)"], in: root, error: &failure
                )
                return (text: text, failure: failure)
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            self.isLoading = false
            self.error = result.failure
            self.baseText = result.text
        }
    }
}

/// A file compared against a target: a header naming both sides, then the two
/// columns.
struct CompareDiffView: View {
    @ObservedObject var compare: CompareTab
    @ObservedObject private var file: FileTab
    /// Whether this pane is the focused one in its tab.
    var isFocused: Bool = true
    var onFocused: () -> Void = {}

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    init(compare: CompareTab, isFocused: Bool = true, onFocused: @escaping () -> Void = {}) {
        _compare = ObservedObject(wrappedValue: compare)
        _file = ObservedObject(wrappedValue: compare.file)
        self.isFocused = isFocused
        self.onFocused = onFocused
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = file.saveError {
                saveErrorBar(error)
            }
            if compare.isUnaligned {
                noticeBar(String(
                    localized: "This file is too large to line up side by side. Both versions are shown in full, but matching lines are not levelled."
                ))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            compare.reload()
            file.reloadFromDiskIfClean()
        }
        // The pane stays mounted while Terminal is inactive, so returning from
        // an external editor — or from an agent's run — does not fire onAppear.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            file.reloadFromDiskIfClean()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            file.reloadFromDiskIfClean()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = compare.error {
            placeholder(icon: "exclamationmark.triangle", text: error)
        } else if case .unavailable(let reason) = file.content, !compare.isDeletedFromWorkingTree {
            // A file the working tree no longer has is not an error — it is
            // the comparison. Only a genuinely unreadable file (binary, too
            // large) stops here; a deletion renders target-against-empty,
            // which is the whole reason for opening it.
            placeholder(icon: "doc", text: reason)
        } else {
            CompareColumnsView(
                baseText: compare.baseText,
                file: file,
                repository: compare.repository,
                path: compare.path,
                targetPath: compare.origPath ?? compare.path,
                targetOID: compare.targetOID,
                targetName: compare.targetName,
                showsLineBlame: settings.compareLineBlame,
                font: TerminalFont.current(),
                palette: .theme(dark: colorScheme == .dark),
                isFocused: isFocused,
                onFocused: onFocused,
                onAlignment: { compare.isUnaligned = $0 }
            )
            // A fresh read of either side is a different document; rebuilding
            // is what re-runs the alignment from scratch.
            .id(ColumnIdentity(base: compare.baseText, revision: file.reloadRevision))
        }
    }

    /// Rebuild key for the columns. The base text is part of it because a
    /// target that resolves to different content is a different comparison.
    private struct ColumnIdentity: Hashable {
        let base: String
        let revision: UInt
    }

    private var header: some View {
        HStack(spacing: 0) {
            columnLabel(
                title: compare.targetName,
                detail: compare.shortOID,
                isDirty: false,
                help: String(localized: "The file as of \(compare.targetName) (\(compare.shortOID)) — read-only")
            )
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            columnLabel(
                title: compare.path,
                detail: compare.remoteHost,
                // The dot is the only state worth a glyph here: everything else
                // in this bar is fixed, and the word "editable" never changed.
                isDirty: file.isDirty,
                help: compare.remoteHost.map { host in
                    String(
                        localized: "The working tree on \(host) — read-only",
                        comment: "Compare header for a working tree on a remote host. The placeholder is a hostname."
                    )
                } ?? String(localized: "Your working tree — edit here and press ⌘S to save")
            )
        }
        // Fixed: the column divider is a rectangle with no height of its own,
        // so without this the header stretched to fill the pane and left the
        // two labels floating in the middle of it.
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private func columnLabel(
        title: String, detail: String?, isDirty: Bool, help: String
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if isDirty {
                Circle()
                    .fill(Color(red: 0.82, green: 0.60, blue: 0.13))
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private func saveErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            // A conflict already reads as a full sentence; only a raw failure
            // needs the explanatory prefix.
            Group {
                if file.saveConflict {
                    Text(message)
                } else {
                    Text("Could not save: \(message)")
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            Spacer(minLength: 0)
            if file.saveConflict {
                Button("Overwrite") { file.saveOverwritingChanges() }
                Button("Reload") { file.discardChangesAndReload() }
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    private func noticeBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The two columns: the target on the left, read-only; the file on disk on the
/// right, editable.
private struct CompareColumnsView: NSViewRepresentable {
    let baseText: String
    let file: FileTab
    /// The repository both columns blame against, and the machine it is on.
    let repository: GitDirectory
    /// The working-tree path — what the editable column blames against.
    let path: String
    /// The path at the target, which differs from `path` for a rename. The
    /// read-only column blames the file's own history under that name.
    let targetPath: String
    let targetOID: String
    let targetName: String
    let showsLineBlame: Bool
    let font: NSFont
    let palette: EditorPalette
    var isFocused: Bool
    var onFocused: () -> Void
    var onAlignment: (Bool) -> Void

    func makeCoordinator() -> CompareColumnsCoordinator {
        CompareColumnsCoordinator(
            file: file, repository: repository, path: path,
            targetPath: targetPath, targetOID: targetOID, targetName: targetName
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let coordinator = context.coordinator
        let split = CompareSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.themeDividerColor = Theme.divider

        let left = coordinator.makeColumn(
            path: path, editable: false, font: font, palette: palette, onFocused: {}
        )
        let right = coordinator.makeColumn(
            path: path, editable: true, font: font, palette: palette, onFocused: onFocused
        )
        coordinator.showsLineBlame = showsLineBlame
        coordinator.onAlignment = onAlignment
        coordinator.attach(old: left, new: right)
        split.addArrangedSubview(left.scrollView)
        split.addArrangedSubview(right.scrollView)

        coordinator.load(baseText: baseText, newText: file.text)

        if isFocused {
            DispatchQueue.main.async {
                right.textView.window?.makeFirstResponder(right.textView)
            }
        }
        coordinator.wasFocused = isFocused
        // The editable column, not the split: this is what Find aims at (see
        // `FileTab.textView`) and what a pane-move drag snapshots.
        file.editorView = right.scrollView
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFocused = onFocused
        coordinator.onAlignment = onAlignment
        coordinator.setLineBlame(enabled: showsLineBlame)
        coordinator.apply(font: font, palette: palette)
        if isFocused, !coordinator.wasFocused {
            DispatchQueue.main.async {
                coordinator.newColumn?.textView.window?.makeFirstResponder(
                    coordinator.newColumn?.textView
                )
            }
        }
        coordinator.wasFocused = isFocused
    }

    /// Take exactly the space SwiftUI offers, for the same reason
    /// `SourceTextEditor.sizeThatFits` does: an STTextView's fitting size is
    /// derived from the whole document, and letting that drive the window size
    /// pushes the layout into an unbounded loop.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSSplitView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }

    static func dismantleNSView(_ split: NSSplitView, coordinator: CompareColumnsCoordinator) {
        coordinator.detach()
    }
}

/// The comparison's own split view. `NSSplitView`'s stock thin divider is a
/// near-black hairline against a dark terminal theme — invisible exactly where
/// the two sides most need to be told apart.
private final class CompareSplitView: NSSplitView {
    var themeDividerColor: NSColor = .separatorColor

    override var dividerColor: NSColor { themeDividerColor }
}

/// A column's scroll view, which also centres the "nothing on this side"
/// notice. The notice is placed here rather than constrained as an ordinary
/// subview because a scroll view lays its own subviews out and Auto Layout
/// constraints against it are simply dropped.
private final class CompareScrollView: NSScrollView {
    let emptyLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Kept above the text, and centred on the viewport rather than the
        // document, so it stays put instead of scrolling away.
        if emptyLabel.superview !== self || subviews.last !== emptyLabel {
            emptyLabel.removeFromSuperview()
            addSubview(emptyLabel)
        }
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(
            x: ((bounds.width - emptyLabel.frame.width) / 2).rounded(),
            y: ((bounds.height - emptyLabel.frame.height) / 2).rounded()
        )
    }
}

/// A column's document view, with the text view placed inside it rather than
/// being the document view itself.
///
/// This exists for one reason: a column sometimes needs blank rows *above* its
/// first line, and nothing inside the text can produce them.
/// `paragraphSpacingBefore` is ignored on the first paragraph, and
/// `minimumLineHeight` puts its space below the text rather than above. A
/// scroll-view `contentInsets.top` looked like the answer and is not — it
/// repositions the gutter without moving the text, so the numbers part company
/// with their lines.
///
/// Offsetting the whole text view moves the gutter with it, because the gutter
/// is one of its subviews. The blank rows are then simply the scroll view's
/// background showing above it.
private final class CompareDocumentView: NSView {
    let textView: CompareTextView
    /// Blank space above the first line, in points.
    var leadingInset: CGFloat = 0 {
        didSet {
            guard leadingInset != oldValue else { return }
            needsLayout = true
            syncSize()
        }
    }

    private var frameObserver: (any NSObjectProtocol)?
    /// Resizing the container changes the scroll view's document rect, which
    /// can make the text view resize itself straight back. Without this the
    /// two chase each other until the stack runs out.
    private var isSyncingSize = false

    override var isFlipped: Bool { true }

    init(textView: CompareTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        // STTextView sizes itself from its content; the container has to grow
        // to match, plus whatever gap sits above it.
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSize() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    override func layout() {
        super.layout()
        if textView.frame.origin.y != leadingInset || textView.frame.origin.x != 0 {
            textView.frame.origin = NSPoint(x: 0, y: leadingInset)
        }
    }

    private func syncSize() {
        guard !isSyncingSize else { return }
        let viewport = enclosingScrollView?.contentSize ?? .zero
        // Rounded so a sub-pixel difference cannot keep the two views trading
        // resizes forever.
        let size = NSSize(
            width: max(textView.frame.width, viewport.width).rounded(),
            height: (textView.frame.height + leadingInset).rounded()
        )
        guard frame.size != size else { return }
        isSyncingSize = true
        setFrameSize(size)
        isSyncingSize = false
        needsLayout = true
    }
}

/// One column of the comparison.
private final class CompareColumn {
    let scrollView: CompareScrollView
    let textView: CompareTextView
    let documentView: CompareDocumentView

    init(scrollView: CompareScrollView, documentView: CompareDocumentView) {
        self.scrollView = scrollView
        self.documentView = documentView
        textView = documentView.textView
    }

    /// Blank rows above this column's first line.
    var leadingInset: CGFloat {
        get { documentView.leadingInset }
        set { documentView.leadingInset = newValue }
    }

    /// Names why a column is blank — an added or deleted file — instead of
    /// leaving half the comparison as an empty pane.
    func showEmptyNotice(_ text: String?) {
        scrollView.emptyLabel.stringValue = text ?? ""
        scrollView.emptyLabel.isHidden = text == nil
        scrollView.needsLayout = true
    }
}

/// Builds both columns, keeps them level and scrolled together, and re-runs the
/// alignment whenever either side changes.
@MainActor
private final class CompareColumnsCoordinator: NSObject, STTextViewDelegate {
    private let file: FileTab
    private let repository: GitDirectory
    private let path: String
    private let targetPath: String
    private let targetOID: String
    private let targetName: String
    var onFocused: () -> Void = {}
    var wasFocused = false
    var showsLineBlame = true

    private(set) var oldColumn: CompareColumn?
    private(set) var newColumn: CompareColumn?

    private var observers: [any NSObjectProtocol] = []
    /// Guards the two scroll observers against echoing each other forever.
    private var isMirroringScroll = false
    /// Debounces realignment while the user types.
    private var realignWork: DispatchWorkItem?
    /// Invalidates an alignment whose text has moved on before it finished.
    private var alignGeneration: UInt = 0
    /// Reports whether the last alignment gave up on levelling the columns.
    var onAlignment: ((Bool) -> Void)?
    /// Debounces the blame lookup as the caret or the pointer moves.
    private var blameWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    /// Invalidates a blame whose caret or contents have moved on.
    private var blameRequestID: UInt = 0
    private var hoverRequestID: UInt = 0

    init(
        file: FileTab, repository: GitDirectory, path: String,
        targetPath: String, targetOID: String, targetName: String
    ) {
        self.file = file
        self.repository = repository
        self.path = path
        self.targetPath = targetPath
        self.targetOID = targetOID
        self.targetName = targetName
    }

    deinit {
        // `observers` holds opaque tokens, so removal is safe off the main actor.
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Background for a column. The read-only side sits one surface step back
    /// from the editable one, so which half you are typing in is obvious
    /// without reading the header — the two used to be the same colour, with
    /// only a hairline between them.
    private static func background(_ palette: EditorPalette, editable: Bool) -> NSColor {
        editable ? palette.background : palette.lineHighlight
    }

    func makeColumn(
        path: String, editable: Bool, font: NSFont, palette: EditorPalette,
        onFocused: @escaping () -> Void
    ) -> CompareColumn {
        let scrollView = CompareScrollView()
        let textView = CompareTextView()
        textView.onBecomeFirstResponder = onFocused
        textView.offersSplitMenuItems = false
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // Same reasons as SourceTextEditor: the window uses a full-size content
        // view, and the gutter is a document-height floating subview.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true
        let documentView = CompareDocumentView(textView: textView)
        scrollView.documentView = documentView

        textView.showsLineNumbers = true
        textView.highlightSelectedLine = editable
        textView.isIncrementalSearchingEnabled = true
        textView.isEditable = editable
        // Rows must stay one line tall: the columns are levelled by adding
        // whole rows of blank space, so a soft-wrapped line — two rows on one
        // side and one on the other — would put the two sides permanently out
        // of step. The compare view scrolls horizontally instead of wrapping,
        // whatever the editor's own wrap setting is.
        textView.isHorizontallyResizable = true
        apply(font: font, palette: palette, to: textView, scrollView: scrollView)

        if let plugin = SyntaxHighlighting.plugin(for: path) {
            textView.addPlugin(plugin)
        }

        return CompareColumn(scrollView: scrollView, documentView: documentView)
    }

    func attach(old: CompareColumn, new: CompareColumn) {
        oldColumn = old
        newColumn = new
        new.textView.textDelegate = self
        old.textView.onHoverLine = { [weak self] line in
            self?.scheduleHover(line: line, editable: false)
        }
        new.textView.onHoverLine = { [weak self] line in
            self?.scheduleHover(line: line, editable: true)
        }
        mirrorScroll(from: old, to: new)
        mirrorScroll(from: new, to: old)
    }

    func setLineBlame(enabled: Bool) {
        guard showsLineBlame != enabled else { return }
        showsLineBlame = enabled
        if enabled {
            scheduleBlame()
        } else {
            blameWork?.cancel()
            blameRequestID &+= 1
            for column in [oldColumn, newColumn].compactMap({ $0 }) {
                column.textView.blameAnnotation = nil
                column.textView.needsDisplay = true
            }
        }
    }

    func detach() {
        realignWork?.cancel()
        realignWork = nil
        blameWork?.cancel()
        blameWork = nil
        hoverWork?.cancel()
        hoverWork = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// Keeps the two columns showing the same rows. Both documents carry their
    /// own leading gap, so matching lines sit at the same document offset and
    /// mirroring it directly is what puts them on the same screen row.
    private func mirrorScroll(from source: CompareColumn, to destination: CompareColumn) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: source.scrollView.contentView,
            queue: .main
        ) { [weak self, weak source, weak destination] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isMirroringScroll,
                      let source, let destination else { return }
                let desired = source.scrollView.contentView.bounds.origin.y
                let target = destination.scrollView.contentView
                guard abs(target.bounds.origin.y - desired) > 0.5 else { return }
                self.isMirroringScroll = true
                target.setBoundsOrigin(NSPoint(x: target.bounds.origin.x, y: desired))
                destination.scrollView.reflectScrolledClipView(target)
                self.isMirroringScroll = false
            }
        }
        observers.append(observer)
    }

    func load(baseText: String, newText: String) {
        guard let oldColumn, let newColumn else { return }
        oldColumn.textView.text = baseText
        newColumn.textView.text = newText
        // Only one side can be empty against a non-empty other side, and that
        // is exactly the added/deleted case worth naming.
        oldColumn.showEmptyNotice(
            baseText.isEmpty && !newText.isEmpty
                ? String(
                    localized: "Not in \(targetName)",
                    comment: "Shown over the target column when the file does not exist there."
                )
                : nil
        )
        newColumn.showEmptyNotice(
            newText.isEmpty && !baseText.isEmpty
                ? String(localized: "Deleted from your working tree")
                : nil
        )
        realign()
        scheduleBlame()
    }

    // MARK: - Blame

    /// Blames the caret's line on the editable column. Debounced: moving the
    /// caret with the arrow keys would otherwise spawn a `git blame` per
    /// keystroke.
    private func scheduleBlame() {
        guard showsLineBlame else { return }
        blameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.blameCaretLine() }
        }
        blameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func blameCaretLine() {
        guard showsLineBlame, let column = newColumn else { return }
        let textView = column.textView
        let text = textView.text ?? ""
        let caret = textView.textSelection.location
        let line = Self.lineIndex(forUTF16Offset: caret, in: textView.lineStarts)
        guard line >= 0 else { return }

        blameRequestID &+= 1
        let requestID = blameRequestID
        let root = repository
        let path = self.path
        // The buffer, not the file on disk: the annotation has to stay right
        // while there are unsaved edits, and a line just typed has to read as
        // uncommitted rather than inheriting its neighbour's commit.
        let contents = text

        Task { [weak self] in
            let blame = await Task.detached(priority: .utility) {
                GitBlame.line(line + 1, path: path, contents: contents, in: root)
            }.value
            guard let self, self.blameRequestID == requestID,
                  let column = self.newColumn else { return }
            column.textView.blameAnnotation = blame.map { (line: line, blame: $0) }
            column.textView.needsDisplay = true
        }
    }

    /// Loads the hovered line's blame into the column's tooltip. Runs for both
    /// columns: the read-only side blames the target commit, so hovering it
    /// answers "what did this line look like there, and who wrote it?".
    private func scheduleHover(line: Int, editable: Bool) {
        hoverWork?.cancel()
        guard line >= 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.loadHover(line: line, editable: editable) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func loadHover(line: Int, editable: Bool) {
        guard let column = editable ? newColumn : oldColumn else { return }
        hoverRequestID &+= 1
        let requestID = hoverRequestID
        let root = repository
        let path = editable ? self.path : self.targetPath
        // The read-only column is the file as of the target, so it is blamed at
        // that commit; passing its text as `--contents` instead would blame a
        // detached buffer and lose the commit that actually produced it.
        let contents = editable ? (column.textView.text ?? "") : nil
        let revision = editable ? nil : targetOID

        Task { [weak self] in
            let blame = await Task.detached(priority: .utility) { () -> BlameLine? in
                guard let revision else {
                    return GitBlame.line(line + 1, path: path, contents: contents, in: root)
                }
                return GitBlame.line(
                    line + 1, path: path, contents: nil, revision: revision, in: root
                )
            }.value
            guard let self, self.hoverRequestID == requestID,
                  let column = editable ? self.newColumn : self.oldColumn else { return }
            column.textView.hoverTooltip = blame.map { blame in
                (line: line, text: Self.hoverText(blame))
            }
        }
    }

    private static func hoverText(_ blame: BlameLine) -> String {
        guard !blame.isUncommitted else {
            return String(
                localized: "Not committed yet",
                comment: "Blame hover for a line that is not in any commit."
            )
        }
        var lines = [blame.summary.isEmpty
            ? String(localized: "(no commit subject)") : blame.summary]
        let date = blame.fullDate
        lines.append(date.isEmpty ? blame.author : "\(blame.author) — \(date)")
        lines.append(blame.shortOID)
        return lines.joined(separator: "\n")
    }

    /// Which line an offset falls on, by binary search over the line starts.
    static func lineIndex(forUTF16Offset offset: Int, in starts: [Int]) -> Int {
        guard !starts.isEmpty else { return -1 }
        var low = 0
        var high = starts.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func apply(font: NSFont, palette: EditorPalette) {
        for column in [oldColumn, newColumn].compactMap({ $0 }) {
            let changedFont = column.textView.font != font
            apply(
                font: font, palette: palette,
                to: column.textView, scrollView: column.scrollView
            )
            // A different font is a different row height, so every gap has to
            // be recomputed against it.
            if changedFont { scheduleRealign() }
        }
    }

    private func apply(
        font: NSFont, palette: EditorPalette,
        to textView: CompareTextView, scrollView: CompareScrollView
    ) {
        let background = Self.background(palette, editable: textView.isEditable)
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != palette.text {
            textView.textColor = palette.text
        }
        if textView.backgroundColor != background {
            textView.backgroundColor = background
            scrollView.backgroundColor = background
        }
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedLineHighlightColor = palette.lineHighlight
        if let gutter = textView.gutterView {
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
        }
    }

    // MARK: - Alignment

    private func scheduleRealign() {
        realignWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.realign() }
        }
        realignWork = work
        // Long enough that a burst of typing runs the line diff once, short
        // enough that the columns re-level before the pause reads as a stall.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func realign() {
        guard let oldColumn, let newColumn else { return }
        let oldLines = CompareDiff.lines(oldColumn.textView.text ?? "")
        let newLines = CompareDiff.lines(newColumn.textView.text ?? "")

        // Measured before any gap is applied, so it is the height of a clean
        // row rather than a row plus whatever space precedes it.
        clearGaps(in: oldColumn.textView)
        clearGaps(in: newColumn.textView)
        let rowHeight = measureRowHeight(in: newColumn.textView)
            ?? measureRowHeight(in: oldColumn.textView)
            ?? 0

        // The line diff is O(n·d); on two large, very different files it takes
        // long enough to be felt as a freeze, so it runs off the main actor and
        // the result is applied when it lands. A newer edit wins.
        alignGeneration &+= 1
        let generation = alignGeneration
        Task { [weak self] in
            let alignment = await Task.detached(priority: .userInitiated) {
                CompareDiff.align(old: oldLines, new: newLines)
            }.value
            guard let self, self.alignGeneration == generation,
                  let oldColumn = self.oldColumn, let newColumn = self.newColumn
            else { return }
            self.onAlignment?(alignment.isTruncated)
            self.finishAlign(
                alignment, oldColumn: oldColumn, newColumn: newColumn,
                oldLines: oldLines, newLines: newLines, rowHeight: rowHeight
            )
        }
    }

    private func finishAlign(
        _ alignment: CompareAlignment,
        oldColumn: CompareColumn, newColumn: CompareColumn,
        oldLines: [String], newLines: [String], rowHeight: CGFloat
    ) {
        applyAlignment(
            to: oldColumn, lines: oldLines, gaps: alignment.oldGaps,
            changed: Set(alignment.removedLines), rowHeight: rowHeight,
            tint: Self.removedTint
        )
        applyAlignment(
            to: newColumn, lines: newLines, gaps: alignment.newGaps,
            changed: Set(alignment.addedLines), rowHeight: rowHeight,
            tint: Self.addedTint
        )
    }

    /// Drops the paragraph spacing a previous alignment left behind, so a
    /// recomputed alignment starts from clean rows rather than stacking on the
    /// old gaps.
    private func clearGaps(in textView: CompareTextView) {
        guard textView.hasGaps else { return }
        let length = (textView.text ?? "").utf16.count
        guard length > 0 else { return }
        textView.addAttributes(
            [.paragraphStyle: NSParagraphStyle.default],
            range: NSRange(location: 0, length: length)
        )
        textView.hasGaps = false
    }

    /// Height of one text row, measured from a text segment rather than from a
    /// layout fragment. A fragment is a paragraph, and TextKit folds a
    /// document's trailing empty line into the fragment before it — so a
    /// one-line file's only fragment is two rows tall, and reading fragment
    /// heights made every gap and every tint band twice the size it should be.
    /// A segment is always exactly one line.
    private func measureRowHeight(in textView: CompareTextView) -> CGFloat? {
        let layout = textView.textLayoutManager
        guard !layout.documentRange.isEmpty,
              let range = NSTextRange(
                  NSRange(location: 0, length: 1), in: textView.textContentManager
              )
        else { return nil }
        var height: CGFloat?
        layout.enumerateTextSegments(
            in: range, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            height = frame.height
            return false
        }
        guard let height, height > 0 else { return nil }
        return height
    }

    private func applyAlignment(
        to column: CompareColumn, lines: [String], gaps: [Int: Int],
        changed: Set<Int>, rowHeight: CGFloat, tint: NSColor
    ) {
        let textView = column.textView
        // A gap before line 0 cannot come from the text, so it is applied to
        // the text view's position inside its document view instead — see
        // `CompareDocumentView`. It leaves the row model, because everything
        // this view draws is in its own coordinates, which the offset already
        // accounts for.
        var gaps = gaps
        let leading = CGFloat(gaps.removeValue(forKey: 0) ?? 0) * rowHeight
        column.leadingInset = leading
        // Two moves are needed because the text and its line numbers live in
        // different places. The container above shifts the text view down. The
        // gutter is not one of its subviews — STTextView hands it to the scroll
        // view as a floating subview — so it does not come along, and a
        // matching top inset is what brings it down to meet the text. Measured
        // both ways: the container alone leaves the numbers a gap too high, the
        // inset alone leaves them a gap too low.
        column.scrollView.contentInsets = NSEdgeInsets(
            top: leading, left: 0, bottom: 0, right: 0
        )

        let starts = CompareDiff.lineStartOffsets(lines)
        textView.lineStarts = starts
        textView.changedLines = changed
        textView.changeTint = tint
        textView.rowHeight = rowHeight
        textView.rowOffsets = Self.rowOffsets(lineCount: lines.count, gaps: gaps)
        // Reverse map for hit-testing a hovered row back to its line.
        var rowToLine: [Int: Int] = [:]
        for (line, row) in textView.rowOffsets.enumerated() { rowToLine[row] = line }
        textView.rowToLine = rowToLine

        guard rowHeight > 0, !gaps.isEmpty else {
            textView.needsDisplay = true
            return
        }
        let length = (textView.text ?? "").utf16.count
        for (line, rows) in gaps where line < lines.count && rows > 0 {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = CGFloat(rows) * rowHeight
            // Cover the line and the newline that ends it: a paragraph style
            // applies to the whole paragraph, and an empty line has no other
            // character to carry it.
            let location = starts[line]
            let extent = min(lines[line].utf16.count + 1, max(0, length - location))
            guard location < length else { continue }
            textView.addAttributes(
                [.paragraphStyle: style],
                range: NSRange(location: location, length: max(1, extent))
            )
        }
        textView.hasGaps = true
        textView.needsDisplay = true
    }

    /// Row each line lands on once the blank rows before it are counted.
    private static func rowOffsets(lineCount: Int, gaps: [Int: Int]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lineCount)
        var row = 0
        for line in 0..<max(0, lineCount) {
            row += gaps[line] ?? 0
            offsets.append(row)
            row += 1
        }
        return offsets
    }

    /// Tints strong enough to read at a glance over the terminal's own
    /// background in either appearance, and light enough that syntax colors
    /// stay legible through them.
    private static let removedTint = NSColor.systemRed.withAlphaComponent(0.16)
    private static let addedTint = NSColor.systemGreen.withAlphaComponent(0.16)

    // MARK: - STTextViewDelegate

    func textViewDidChangeText(_ notification: Notification) {
        guard let textView = newColumn?.textView else { return }
        let text = textView.text ?? ""
        guard text != file.text else { return }
        file.text = text
        file.refreshDirtyState()
        scheduleRealign()
        scheduleBlame()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = newColumn?.textView else { return }
        let selection = textView.textSelection
        file.editorState.selectionLocation = selection.location
        file.editorState.selectionLength = selection.length
        scheduleBlame()
    }
}

/// Draws the caret line's blame annotation above the text.
///
/// It cannot be drawn in the text view itself. A text view's own drawing goes
/// underneath its subviews, and the selected-line highlight is one of them —
/// covering exactly the line the annotation belongs to, so the annotation was
/// painted and then hidden every single time.
private final class CompareAnnotationOverlay: NSView {
    weak var owner: CompareTextView?

    override var isFlipped: Bool { true }
    /// Purely decorative: clicks belong to the text underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawBlameAnnotation(in: dirtyRect)
    }
}

/// A comparison column's text view: an ordinary editor that also paints the
/// rows that differ from the other side.
///
/// The tint is drawn here rather than as an attribute because a background
/// color attribute covers only the width of the text, and a changed row has to
/// read as a full-width band the way it does in any diff.
private final class CompareTextView: FocusReportingTextView {
    /// Zero-based line indices that differ from the other column.
    var changedLines: Set<Int> = []
    var changeTint: NSColor = .clear
    /// Row each line sits on once the blank rows before it are counted.
    var rowOffsets: [Int] = []
    /// Reverse of `rowOffsets`, for hit-testing a hovered row back to a line.
    var rowToLine: [Int: Int] = [:]
    /// UTF-16 offset each line starts at.
    var lineStarts: [Int] = []
    /// Height of one row. Uniform: this view never wraps.
    var rowHeight: CGFloat = 0
    /// Whether paragraph spacing from a previous alignment is still applied.
    var hasGaps = false

    /// Who last changed the caret's line, drawn past the end of that line.
    var blameAnnotation: (line: Int, blame: BlameLine)? {
        didSet { annotationOverlay?.needsDisplay = true }
    }
    private var annotationOverlay: CompareAnnotationOverlay?
    /// Blame for the line under the pointer, surfaced as the view's tooltip.
    var hoverTooltip: (line: Int, text: String)?
    /// Called as the pointer moves onto a new line.
    var onHoverLine: ((Int) -> Void)?

    private var hoveredLine = -1
    private var trackingArea: NSTrackingArea?
    private var toolTipTag: NSView.ToolTipTag?

    // MARK: - Hover

    override func layout() {
        super.layout()
        let overlay = annotationOverlay ?? {
            let created = CompareAnnotationOverlay()
            created.owner = self
            annotationOverlay = created
            return created
        }()
        // STTextView adds its own subviews as it lays out, so the overlay is
        // put back on top whenever something lands above it.
        if overlay.superview !== self || subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay)
        }
        if overlay.frame != bounds { overlay.frame = bounds }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area

        // One tooltip rect over the whole view; the owner callback below picks
        // the line, so there is no need to re-register a rect per line as the
        // document changes.
        if let toolTipTag { removeToolTip(toolTipTag) }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let line = self.line(at: point)
        guard line != hoveredLine else { return }
        hoveredLine = line
        // The pointer left the line the cached tooltip described.
        if hoverTooltip?.line != line { hoverTooltip = nil }
        if line >= 0 { onHoverLine?(line) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredLine = -1
        hoverTooltip = nil
    }

    /// The line under a point, or -1 for a blank alignment row or past the end.
    private func line(at point: NSPoint) -> Int {
        guard rowHeight > 0 else { return -1 }
        let row = Int(((point.y - contentFrame.minY) / rowHeight).rounded(.down))
        guard row >= 0 else { return -1 }
        return rowToLine[row] ?? -1
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard rowHeight > 0, !rowOffsets.isEmpty else { return }

        let origin = contentFrame.minY
        // Text starts after the gutter; painting from the view's leading edge
        // would cover the line numbers.
        let leading = gutterView?.frame.maxX ?? 0
        let width = max(0, bounds.width - leading)
        guard width > 0 else { return }

        // Only the rows the redraw actually covers.
        let firstRow = max(0, Int(((dirtyRect.minY - origin) / rowHeight).rounded(.down)))
        let lastRow = Int(((dirtyRect.maxY - origin) / rowHeight).rounded(.up))
        guard lastRow >= firstRow else { return }

        if !changedLines.isEmpty {
            changeTint.setFill()
            for line in changedLines where line < rowOffsets.count {
                let row = rowOffsets[line]
                guard row >= firstRow, row <= lastRow else { continue }
                NSRect(
                    x: leading,
                    y: origin + CGFloat(row) * rowHeight,
                    width: width,
                    height: rowHeight
                ).fill()
            }
        }
    }

    /// Draws the caret line's blame past the end of its text, dimmed enough to
    /// read as an annotation rather than as part of the file. Called by the
    /// overlay above the text, never from this view's own `draw`.
    func drawBlameAnnotation(in dirtyRect: NSRect) {
        guard let annotation = blameAnnotation,
              annotation.line < rowOffsets.count,
              rowHeight > 0
        else { return }
        let font = self.font
        let origin = contentFrame.minY
        let row = rowOffsets[annotation.line]
        let rowTop = origin + CGFloat(row) * rowHeight
        guard rowTop + rowHeight >= dirtyRect.minY, rowTop <= dirtyRect.maxY else { return }
        guard let end = lineEndX(forLine: annotation.line) else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(0.38),
        ]
        let text = annotation.blame.inlineAnnotation as NSString
        let size = text.size(withAttributes: attributes)
        // A gap of a couple of characters so the annotation never reads as a
        // continuation of the code.
        let gap = font.maximumAdvancement.width * 2
        // `end` comes from the layout, which measures inside the content view;
        // this draws in the text view's own space, where the content starts
        // after the gutter. Without that origin the annotation lands a gutter's
        // width too far left, on top of the code it annotates.
        let x = contentFrame.minX + end + gap
        guard x + size.width > 0 else { return }
        text.draw(at: NSPoint(x: x, y: rowTop), withAttributes: attributes)
    }

    /// Where a line's text ends, taken from the layout rather than assumed from
    /// a character count: a tab does not advance by one character width.
    private func lineEndX(forLine line: Int) -> CGFloat? {
        guard line < lineStarts.count else { return nil }
        let length = (text ?? "").utf16.count
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count
            // The next line's start is one past this line's newline.
            ? max(start, lineStarts[line + 1] - 1)
            : length
        guard start <= length, end <= length else { return nil }
        guard let range = NSTextRange(
            NSRange(location: start, length: end - start), in: textContentManager
        ) else { return nil }

        var maxX: CGFloat?
        textLayoutManager.enumerateTextSegments(
            in: range, type: .standard, options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            maxX = max(maxX ?? 0, frame.maxX)
            return true
        }
        return maxX
    }
}

extension CompareTextView: NSViewToolTipOwner {
    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        // Synchronous by contract, so this can only report what the hover
        // lookup has already cached; the first hover over a line shows nothing
        // and the next one, moments later, has the answer.
        guard let hoverTooltip, hoverTooltip.line == hoveredLine else { return "" }
        return hoverTooltip.text
    }
}
