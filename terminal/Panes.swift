//
//  Panes.swift
//  terminal
//

import Combine
import CoreGraphics
import Foundation
import TerminalCore

/// The leaf content of a pane: a terminal session, an open file, a browser, a
/// git diff, or a file compared against a branch or commit. A project tab used
/// to *be* one of these; now a tab is a recursive split layout, and this is
/// what sits at each leaf.
enum PaneContent: nonisolated Identifiable {
    case session(TerminalSession)
    case file(FileTab)
    case browser(BrowserTab)
    case diff(DiffTab)
    case compare(CompareTab)

    nonisolated var id: UUID {
        switch self {
        case .session(let session): return session.id
        case .file(let file): return file.id
        case .browser(let browser): return browser.id
        case .diff(let diff): return diff.id
        case .compare(let compare): return compare.id
        }
    }

    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

extension PaneContent {
    /// Label for the tab strip and pane chrome — the focused content's title.
    @MainActor var title: String {
        switch self {
        case .session(let session): return session.title
        case .file(let file): return file.name
        case .browser(let browser): return browser.title
        case .diff(let diff): return diff.title
        case .compare(let compare): return compare.title
        }
    }

    @MainActor var systemImage: String {
        switch self {
        case .session: return "terminal"
        case .file: return "doc.text"
        case .browser: return "globe"
        case .diff: return "plus.forwardslash.minus"
        case .compare: return "arrow.left.and.right.square"
        }
    }

    @MainActor var isDirty: Bool {
        switch self {
        case .file(let file): return file.isDirty
        // The editable column is a real file buffer, so a comparison holding
        // unsaved edits has to read as dirty everywhere a file tab does.
        case .compare(let compare): return compare.file.isDirty
        default: return false
        }
    }
}

/// One tile in a tab's layout. The content object is long-lived while the pane
/// itself is a value inside the split tree.
struct Pane: nonisolated Identifiable {
    let id = UUID()
    var content: PaneContent
}

// The split tree, its geometry, and the value types that describe it are
// `TerminalCore`'s and carry no notion of what a pane holds. These names keep
// the app's spelling of them, since a layout here is always a tree of `Pane`.
typealias PaneNode = PaneTree<Pane>
typealias PaneSplit = PaneTreeSplit<Pane>
typealias PanePlacement = PaneTreePlacement<Pane>
typealias PaneDividerPlacement = PaneTreeDivider
typealias PaneLayoutGeometry = PaneTreeGeometry<Pane>

/// One entry in a project's tab strip. A plain tab is one leaf; every split
/// replaces one leaf with a binary node while the long-lived content objects
/// remain mounted in their corresponding leaves.
@MainActor
final class PaneTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned tab name; when nil the tab title follows the focused
    /// pane's content (terminal title, file name, diff title) — the same
    /// override scheme as `Project.customName`.
    @Published var customName: String?
    @Published var layout: PaneNode
    @Published var focusedPaneID: UUID
    /// Whether the focused pane is zoomed to fill the tab. Presentation-only:
    /// the split tree and fractions stay intact underneath, and the layout
    /// simply renders the focused pane alone while set — so zoom follows a
    /// focus change instead of hiding it. Cleared by focus navigation and by
    /// anything structural, so those commands always land on a visible layout.
    /// Deliberately not persisted.
    @Published var isZoomed = false

    /// The terminal whose directory this tab is oriented around when it holds
    /// no terminal of its own — captured from the focused session when a file
    /// or diff is opened into a fresh tab. Lets the file-tree / git / info
    /// panels keep tracking the directory the file was opened from instead of
    /// falling back to the project's first session. Weak, so closing that
    /// shell simply drops the association.
    weak var contextSession: TerminalSession?

    /// A fresh single-pane tab wrapping one piece of content.
    init(content: PaneContent) {
        let pane = Pane(content: content)
        layout = .pane(pane)
        focusedPaneID = pane.id
    }

    /// Restores a saved layout.
    init(layout: PaneNode, focusedPaneID: UUID) {
        self.layout = layout
        self.focusedPaneID = focusedPaneID
    }

    // MARK: - Derived

    var allPanes: [Pane] { layout.allPanes }
    var allContents: [PaneContent] { allPanes.map(\.content) }

    var focusedPane: Pane? { allPanes.first { $0.id == focusedPaneID } }
    var focusedContent: PaneContent? { focusedPane?.content }

    /// Title for the tab strip and Window menu: the user-assigned name when
    /// set, else the focused pane's own title.
    var displayTitle: String? {
        if let customName, !customName.isEmpty { return customName }
        return focusedContent?.title
    }

    var sessions: [TerminalSession] {
        allContents.compactMap { if case .session(let session) = $0 { return session }; return nil }
    }

    var diffs: [DiffTab] {
        allContents.compactMap { if case .diff(let diff) = $0 { return diff }; return nil }
    }

    var compares: [CompareTab] {
        allContents.compactMap {
            if case .compare(let compare) = $0 { return compare }
            return nil
        }
    }

    var browsers: [BrowserTab] {
        allContents.compactMap {
            if case .browser(let browser) = $0 { return browser }
            return nil
        }
    }

    var hasMultiplePanes: Bool { allPanes.count > 1 }

    /// Splitting is disallowed while a diff or a comparison is focused. Diffs
    /// stay in their own single-pane tab so their always-mounted web view keeps
    /// filling it; a comparison is already a two-column split of its own, and
    /// halving it again leaves neither column readable.
    var canSplit: Bool {
        switch focusedContent {
        case .diff, .compare: return false
        default: return true
        }
    }

    // MARK: - Navigation

    func focusUp() { moveWithinColumn(-1) }
    func focusDown() { moveFocus(.down) }
    func focusLeft() { moveFocus(.left) }
    func focusRight() { moveFocus(.right) }
    /// Cycles focus through every pane in split-tree order, wrapping at the
    /// ends.
    func focusNext() { cycleFocus(1) }
    func focusPrevious() { cycleFocus(-1) }

    private enum FocusDirection {
        case left, right, up, down
    }

    private func moveWithinColumn(_ delta: Int) {
        moveFocus(delta < 0 ? .up : .down)
    }

    /// Picks the closest pane in the requested geometric direction. Prefer a
    /// pane overlapping the focused pane on the perpendicular axis, then the
    /// nearest edge and centre.
    private func moveFocus(_ direction: FocusDirection) {
        unzoom()
        let placements = layout.geometry(
            in: CGRect(x: 0, y: 0, width: 1, height: 1), gap: 0
        ).panes
        guard let current = placements.first(where: { $0.pane.id == focusedPaneID })
        else { return }

        let candidates = placements.compactMap { placement -> (UUID, CGFloat)? in
            guard placement.pane.id != focusedPaneID else { return nil }
            let frame = placement.frame
            let primary: CGFloat
            let perpendicularGap: CGFloat
            let centerDistance: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= current.frame.minX + 0.0001 else { return nil }
                primary = current.frame.minX - frame.maxX
                perpendicularGap = intervalGap(
                    frame.minY, frame.maxY, current.frame.minY, current.frame.maxY
                )
                centerDistance = abs(frame.midY - current.frame.midY)
            case .right:
                guard frame.minX >= current.frame.maxX - 0.0001 else { return nil }
                primary = frame.minX - current.frame.maxX
                perpendicularGap = intervalGap(
                    frame.minY, frame.maxY, current.frame.minY, current.frame.maxY
                )
                centerDistance = abs(frame.midY - current.frame.midY)
            case .up:
                guard frame.maxY <= current.frame.minY + 0.0001 else { return nil }
                primary = current.frame.minY - frame.maxY
                perpendicularGap = intervalGap(
                    frame.minX, frame.maxX, current.frame.minX, current.frame.maxX
                )
                centerDistance = abs(frame.midX - current.frame.midX)
            case .down:
                guard frame.minY >= current.frame.maxY - 0.0001 else { return nil }
                primary = frame.minY - current.frame.maxY
                perpendicularGap = intervalGap(
                    frame.minX, frame.maxX, current.frame.minX, current.frame.maxX
                )
                centerDistance = abs(frame.midX - current.frame.midX)
            }
            let score = (perpendicularGap > 0 ? 10 : 0)
                + perpendicularGap * 5 + primary + centerDistance * 0.01
            return (placement.pane.id, score)
        }
        if let closest = candidates.min(by: { $0.1 < $1.1 }) {
            focusedPaneID = closest.0
        }
    }

    private func intervalGap(
        _ firstMin: CGFloat, _ firstMax: CGFloat,
        _ secondMin: CGFloat, _ secondMax: CGFloat
    ) -> CGFloat {
        max(0, max(firstMin, secondMin) - min(firstMax, secondMax))
    }

    private func cycleFocus(_ delta: Int) {
        unzoom()
        let panes = allPanes
        guard panes.count > 1,
              let index = panes.firstIndex(where: { $0.id == focusedPaneID }) else { return }
        focusedPaneID = panes[(index + delta + panes.count) % panes.count].id
    }

    // MARK: - Zoom

    /// Zooms the focused pane out to fill the tab, or restores the layout.
    func toggleZoom() {
        if isZoomed {
            isZoomed = false
        } else if hasMultiplePanes {
            isZoomed = true
        }
    }

    /// Leaves zoom, guarded so the common unzoomed case doesn't fire a
    /// spurious @Published change.
    private func unzoom() {
        if isZoomed { isZoomed = false }
    }

    // MARK: - Structure

    /// Inserts `pane` inside the focused pane's rectangle, taking half of that
    /// rectangle on the requested edge. Focuses the new pane.
    func split(_ pane: Pane, toward edge: PaneDropEdge) {
        unzoom()
        let target = layout.contains(focusedPaneID)
            ? focusedPaneID : layout.allPanes[0].id
        layout = layout.inserting(pane, toward: edge, beside: target)
        focusedPaneID = pane.id
    }

    /// Moves `dragged` next to `target` on the given edge — the drag-to-split
    /// gesture. The target leaf is subdivided on that edge, exactly like a new
    /// split. The moved pane takes half the target's space and focus follows it.
    func movePane(_ dragged: UUID, _ edge: PaneDropEdge, of target: UUID) {
        guard dragged != target, layout.contains(dragged), layout.contains(target) else { return }
        unzoom()
        let result = layout.removingPane(dragged)
        guard let moved = result.pane, let remaining = result.node,
              remaining.contains(target) else { return }
        layout = remaining.inserting(moved, toward: edge, beside: target)
        focusedPaneID = moved.id
    }

    /// Removes the pane with `id`, collapsing the empty split branch and moving
    /// focus to the nearest survivor in tree order. Returns false when the tab
    /// is now empty, so the caller can drop the tab itself.
    @discardableResult
    func removePane(_ id: UUID) -> Bool {
        let panesBefore = allPanes
        guard let index = panesBefore.firstIndex(where: { $0.id == id }) else {
            return !panesBefore.isEmpty
        }
        let wasFocused = focusedPaneID == id
        let result = layout.removingPane(id)
        guard result.pane != nil, let remaining = result.node else { return false }
        layout = remaining
        if wasFocused {
            let survivors = allPanes
            focusedPaneID = survivors[min(index, survivors.count - 1)].id
        }
        // Losing the zoomed pane itself (or the whole split) drops back to the
        // layout; a hidden sibling closing underneath the zoom does not.
        if wasFocused || allPanes.count <= 1 { unzoom() }
        return true
    }

    // MARK: - Keyboard resize

    /// Fraction of an axis's total weight one keyboard-resize step shifts.
    private static let resizeStep: CGFloat = 0.05
    /// Smallest share any tile may be shrunk to — the same floor the drag
    /// dividers enforce (`PaneLayoutView.minFraction`).
    private static let minShare: CGFloat = 0.1

    func resizeUp() { resizeRows(toward: -1) }
    func resizeDown() { resizeRows(toward: 1) }
    func resizeLeft() { resizeColumns(toward: -1) }
    func resizeRight() { resizeColumns(toward: 1) }

    /// Sets every adjacent run of panes back to equal shares.
    func equalize() {
        unzoom()
        guard hasMultiplePanes else { return }
        layout = layout.equalized()
    }

    /// Pushes the nearest horizontal ancestor divider one step left or right
    /// (`direction` -1/+1): the divider on the pressed side when there is one,
    /// so the focused branch grows that way; at an edge the opposite divider
    /// moves instead, shrinking the branch — both keys always do something.
    private func resizeColumns(toward direction: Int) {
        resizeSplit(axis: .horizontal, toward: direction)
    }

    /// Same as `resizeColumns`, for the nearest vertical ancestor divider.
    private func resizeRows(toward direction: Int) {
        resizeSplit(axis: .vertical, toward: direction)
    }

    private func resizeSplit(axis: PaneSplitAxis, toward direction: Int) {
        unzoom()
        guard let ancestors = layout.ancestors(of: focusedPaneID) else { return }
        let matching = ancestors.reversed().filter { $0.axis == axis }
        guard let split = matching.first(where: {
            $0.paneIsInFirstChild == (direction > 0)
        }) ?? matching.first,
        let fraction = layout.fraction(of: split.id) else { return }
        let next = min(
            max(fraction + CGFloat(direction) * Self.resizeStep, Self.minShare),
            1 - Self.minShare
        )
        guard next != fraction else { return }
        layout = layout.settingFraction(of: split.id, to: next)
    }

    // MARK: - Location helpers

    /// The id of the pane currently holding `contentID`.
    func paneID(forContent contentID: UUID) -> UUID? {
        allPanes.first { $0.content.id == contentID }?.id
    }
}
