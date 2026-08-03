//
//  TerminalFind.swift
//  TerminalCore
//

import Combine
import Foundation

/// One Find menu command, routed from the menu bar to whichever find
/// implementation the focused pane owns: the backend's own search in a
/// terminal, `NSTextFinder`'s find bar in a file editor.
public enum FindAction {
    case show
    case replace
    case hide
    case next
    case previous
    case useSelection
}

/// What ``TerminalFind`` needs of the surface it drives — the backend's own
/// search, and nothing else. The app's `TerminalBackendSurface` conforms; this
/// narrow spelling is what lets the state machine below be driven by a stub.
public protocol TerminalFindSurface: AnyObject {
    /// Whether anything is selected in the grid.
    var hasSelection: Bool { get }

    /// Starts or replaces the find for `needle`.
    func beginFind(_ needle: String)

    /// Ends the active find and clears its highlights.
    func endFind()

    /// Moves the selection to the next or previous match.
    func stepFind(forward: Bool)

    /// Starts a find for whatever is selected in the grid.
    func findSelection()
}

/// Find-in-terminal state for one session.
///
/// The backend owns the search itself — it scans the screen and scrollback on
/// its own thread, highlights every match in its renderer, and moves the
/// selection as you navigate — so this holds only what the find bar draws and
/// forwards the user's intent as surface find actions. Match counts arrive
/// back asynchronously through `TerminalBackendEvents`.
@MainActor
public final class TerminalFind: nonisolated ObservableObject {
    @Published public private(set) var isPresented = false

    /// The needle. Every edit restarts the backend's search, so the bar
    /// searches as you type.
    @Published public var query = "" {
        didSet {
            guard query != oldValue, !isApplyingReportedNeedle else { return }
            runSearch()
        }
    }

    /// Matches found so far, or nil while a count for the current needle has
    /// not been reported yet.
    @Published public private(set) var total: Int?
    /// Zero-based index of the highlighted match, nil when none is.
    @Published public private(set) var selected: Int?

    /// Bumped whenever the bar should take (or retake) keyboard focus, so ⌘F
    /// on an already-open bar re-selects the term the way the system find bar
    /// does. A counter rather than a flag: repeated requests must each land.
    @Published public private(set) var focusRequest = 0

    /// The session owning this also owns the surface, so an unowned reference
    /// is safe and keeps the session's object graph acyclic.
    public unowned let surface: any TerminalFindSurface

    /// Set while a needle the backend resolved for us (⌘E's selection) is
    /// being written into `query`, so echoing it back as a fresh search —
    /// which would restart the one already running — is suppressed.
    private var isApplyingReportedNeedle = false

    /// Bumped per search so a deferred reveal belonging to an older needle can
    /// tell it has been superseded. A backend reports each restart as a burst
    /// of counts, several per keystroke.
    private var searchGeneration = 0
    /// Whether the current needle has already jumped to a match.
    private var hasRevealedMatch = false

    public init(surface: any TerminalFindSurface) {
        self.surface = surface
    }

    // MARK: - Find menu

    public func perform(_ action: FindAction) {
        switch action {
        case .show: present()
        case .hide: dismiss()
        case .next: navigate(forward: true)
        case .previous: navigate(forward: false)
        case .useSelection: searchSelection()
        // Terminal output is read-only, so Find and Replace stays disabled
        // while a terminal is focused and never arrives here.
        case .replace: break
        }
    }

    // MARK: - Commands

    /// Shows the bar and focuses its field. The needle survives a close, so
    /// reopening offers the previous term again, pre-selected.
    public func present() {
        isPresented = true
        focusRequest += 1
        runSearch()
    }

    /// Closes the bar, clears the backend's highlights, and hands typing back
    /// to the terminal.
    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        clearCounts()
        surface.endFind()
    }

    public func navigate(forward: Bool) {
        guard !query.isEmpty else { return }
        // ⌘G with the bar closed resumes the last search rather than doing
        // nothing, matching how Find Next behaves elsewhere on macOS.
        guard isPresented else {
            present()
            return
        }
        surface.stepFind(forward: forward)
    }

    /// ⌘E. The backend resolves the needle from the grid selection and reports
    /// it back through ``started(needle:)``, so the selection never has to be
    /// read out and re-escaped here.
    public func searchSelection() {
        guard surface.hasSelection else { return }
        surface.findSelection()
    }

    // MARK: - Reports from the backend

    public func started(needle: String) {
        // Only claim keyboard focus when this actually opens the bar. A
        // backend may report a start for a search already under way, and
        // re-selecting the field mid-edit would eat what the user is typing.
        if !isPresented {
            isPresented = true
            focusRequest += 1
        }
        guard !needle.isEmpty, needle != query else { return }
        isApplyingReportedNeedle = true
        query = needle
        isApplyingReportedNeedle = false
    }

    /// The backend ended the search on its own. Mirror it without sending
    /// an end straight back at it.
    public func ended() {
        isPresented = false
        clearCounts()
    }

    public func update(total: Int?) {
        self.total = total
        revealFirstMatchIfNeeded()
    }

    public func update(selected: Int?) {
        self.selected = selected
    }

    /// A backend tallies matches but selects none until asked, so the first
    /// non-empty result for a needle jumps to one — typing in the find bar is
    /// meant to reveal the hit, not merely count it. Deferred so it never
    /// re-enters the backend from inside its own action callback, and dropped
    /// when the needle has moved on by the time it runs.
    private func revealFirstMatchIfNeeded() {
        guard !hasRevealedMatch, let total, total > 0 else { return }
        hasRevealedMatch = true
        let generation = searchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, isPresented, searchGeneration == generation else { return }
            surface.stepFind(forward: true)
        }
    }

    // MARK: - Search

    /// Restarts the backend's search for the current needle. Counts are
    /// dropped first so the bar never shows a tally belonging to the previous
    /// term.
    private func runSearch() {
        guard isPresented else { return }
        searchGeneration += 1
        hasRevealedMatch = false
        clearCounts()
        surface.beginFind(query)
    }

    private func clearCounts() {
        total = nil
        selected = nil
    }
}
