//
//  DiffViewerView.swift
//  terminal
//

import AppKit
import Combine
import Foundation
import PierreDiffsSwift
import SwiftUI

/// Observable inputs for a diff tab's web view. Owned by `DiffTab` and also
/// retained by the tab's long-lived hosting view, so it must never reference
/// the `DiffTab` back (that would leak the tab through a retain cycle).
@MainActor
final class DiffWebModel: nonisolated ObservableObject {
    @Published var oldContent = ""
    @Published var newContent = ""
    @Published var fileName = ""
    @Published var diffStyle: DiffStyle = .unified
    @Published var overflowMode: OverflowMode = .scroll
    /// The WKWebView renders blank until its JS bundle has drawn the diff;
    /// a skeleton covers it until the bridge reports ready.
    @Published var isReady = false
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
final class DiffTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String?

    @Published private(set) var error: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isUnmerged = false

    let web = DiffWebModel()

    /// The web view lives on the tab (not in the SwiftUI view) so switching
    /// tabs re-parents the same rendered view instead of booting a fresh
    /// WKWebView — same pattern as `TerminalSession.terminalView`.
    private(set) lazy var webHostView: NSView = NSHostingView(
        rootView: DiffWebRoot(model: web)
    )

    private var reloadGeneration: UInt = 0

    init(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?) {
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        web.fileName = name
        reload()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var title: String {
        staged
            ? String(localized: "\(name) (Staged)", comment: "Tab title for the staged diff of a file.")
            : name
    }

    func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        error = nil
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var failureVar: String?
                let unmerged = !staged && Self.isUnmerged(path: path, in: root)
                let old: String
                let new: String
                if staged {
                    old = GitFileContent.firstBlob(
                        ["HEAD:\(oldPath)"], in: root, error: &failureVar
                    )
                    new = GitFileContent.firstBlob(
                        [":\(path)"], in: root, error: &failureVar
                    )
                } else {
                    if untracked {
                        old = ""
                    } else {
                        // An unmerged index has no stage-0 `:path`. Prefer our
                        // side, then the merge base, so conflict rows show a
                        // meaningful before-side instead of the whole file as new.
                        old = GitFileContent.firstBlob(
                            [":\(oldPath)", ":2:\(oldPath)", ":1:\(oldPath)", "HEAD:\(oldPath)"],
                            in: root,
                            error: &failureVar
                        )
                    }
                    new = GitFileContent.worktreeFile(
                        root: root, path: path, error: &failureVar
                    )
                }
                return (old: old, new: new, failure: failureVar, unmerged: unmerged)
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            self.isLoading = false
            self.error = result.failure
            self.isUnmerged = result.unmerged
            self.web.oldContent = result.old
            self.web.newContent = result.new
        }
    }

    private nonisolated static func isUnmerged(path: String, in root: String) -> Bool {
        let run = GitStatusModel.runGit(
            ["--literal-pathspecs", "ls-files", "--unmerged", "--", path], in: root
        )
        return run.status == 0 && !run.stdout.isEmpty
    }
}

/// Font handling for the diff web view, so a diff reads at the same family and
/// size as the terminal and the editor.
///
/// A family the user picked in Settings is installed system-wide and the web
/// view resolves it by name. terminal's bundled JetBrains Mono is different:
/// `TerminalFont.registerBundledFonts` registers it for this process only, and
/// the diff renders in a separate WebKit content process that cannot see it —
/// so its faces travel to the web view as embedded font data. Reading and
/// encoding them happens once for the whole app.
private enum DiffFont {
    static func renderOptions(family: String, size: Double) -> PierreDiffRenderOptions {
        let usesBundled = family.isEmpty || family == TerminalFont.bundledFamily
        return PierreDiffRenderOptions(
            font: .bundled(
                familyName: usesBundled ? TerminalFont.bundledFamily : family,
                faces: usesBundled ? bundledFaces : [],
                sizePoints: size
            )
        )
    }

    /// All four faces travel, rather than letting the browser synthesize bold
    /// and italic: synthetic faces in a monospace grid do not stay aligned
    /// with the real one.
    private static let bundledFaces: [PierreDiffFontFace] = {
        let variants = [
            ("JetBrainsMono-Regular", "400", "normal"),
            ("JetBrainsMono-Bold", "700", "normal"),
            ("JetBrainsMono-Italic", "400", "italic"),
            ("JetBrainsMono-BoldItalic", "700", "italic"),
        ]
        return variants.compactMap { resource, weight, style in
            PierreDiffFontFace.load(
                family: TerminalFont.bundledFamily,
                resource: resource,
                extension: "ttf",
                weight: weight,
                style: style
            )
        }
    }()
}

/// Root of the tab-owned hosting view: keeps the diff web view (and its
/// WKWebView) alive for the tab's lifetime, re-rendering when the model's
/// inputs change.
///
/// A tab still shows exactly one file. It goes through the multi-file surface
/// holding that single file because that is the virtualized path: rows are
/// rendered only while on screen and syntax highlighting runs in a worker, so
/// opening or scrolling a large diff never stalls the main thread. The
/// single-file view renders every row up front and highlights them inline.
private struct DiffWebRoot: View {
    @ObservedObject var model: DiffWebModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        PierreMultiDiffView(
            files: [
                PierreDiffFile(
                    id: model.fileName,
                    name: model.fileName,
                    oldContents: model.oldContent,
                    newContents: model.newContent
                )
            ],
            diffStyle: $model.diffStyle,
            overflowMode: $model.overflowMode,
            renderOptions: DiffFont.renderOptions(
                family: settings.fontFamily, size: settings.fontSize
            ),
            onReady: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isReady = true
                }
            }
        )
    }
}

/// Re-parents a tab's long-lived web host view into the current tab area;
/// AppKit detaches it from any previous container automatically.
private struct DiffWebHostView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Renders a diff tab with PierreDiffsSwift: syntax-highlighted unified or
/// split view with word-level change highlighting.
struct DiffViewerView: View {
    @ObservedObject var diff: DiffTab
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var web: DiffWebModel
    /// The view stays mounted while other tabs are selected (see
    /// ContentView); this flags when it is the frontmost tab so content
    /// refreshes on each re-visit, not just on first mount.
    let isSelected: Bool

    init(diff: DiffTab, isSelected: Bool = true) {
        _diff = ObservedObject(wrappedValue: diff)
        _web = ObservedObject(wrappedValue: diff.web)
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            if diff.isUnmerged {
                conflictBanner
            }
            Group {
                if let error = diff.error {
                    placeholder(icon: "exclamationmark.triangle", text: error)
                } else if web.oldContent == web.newContent {
                    if diff.isLoading {
                        DiffSkeletonView()
                    } else if diff.isUnmerged {
                        placeholder(
                            icon: "arrow.triangle.merge",
                            text: String(localized: "Conflict is still unresolved")
                        )
                    } else {
                        placeholder(icon: "checkmark.circle", text: String(localized: "No changes"))
                    }
                } else {
                    VStack(spacing: 0) {
                        controlBar
                        DiffWebHostView(view: diff.webHostView)
                            // Cover (never hide) the webview while it boots:
                            // making it invisible lets WebKit throttle rendering
                            // and the initial diff render can be dropped entirely.
                            .overlay {
                                if !web.isReady {
                                    DiffSkeletonView()
                                        .background(Color(nsColor: Theme.background))
                                        .transition(.opacity)
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { diff.reload() }
        .onChange(of: isSelected) {
            if isSelected {
                diff.reload()
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
            Text("Unresolved merge conflict")
                .fontWeight(.medium)
            Spacer(minLength: 0)
            Text("Resolve before committing")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.orange.opacity(0.22))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var controlBar: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("", selection: $web.diffStyle) {
                ForEach(DiffStyle.allCases) { style in
                    Text(verbatim: localizedDiffStyle(style)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Diff Layout")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
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

    private func localizedDiffStyle(_ style: DiffStyle) -> String {
        switch style {
        case .unified:
            return String(localized: "Unified", comment: "A single-column diff layout.")
        case .split:
            return String(localized: "Split", comment: "A side-by-side diff layout.")
        @unknown default:
            return style.displayName
        }
    }
}

/// Code-shaped gray bars shown while the diff web view boots, so opening
/// a diff never flashes an empty pane.
private struct DiffSkeletonView: View {
    /// (indent level, width fraction) per line, repeated to fill the pane.
    private static let pattern: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.42), (1, 0.62), (1, 0.30), (1, 0.55),
        (2, 0.38), (2, 0.50), (1, 0.24), (0, 0.16),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<24, id: \.self) { index in
                    let line = Self.pattern[index % Self.pattern.count]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: geo.size.width * line.width * 0.55, height: 9)
                        .padding(.leading, line.indent * 18)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
