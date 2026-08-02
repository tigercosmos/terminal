//
//  PointerRegion.swift
//  terminal
//

import AppKit
import SwiftUI

/// Which part of Terminal the user last clicked into: the app's own interface,
/// or the pane content it wraps.
///
/// Keyboard focus cannot answer this. The sidebars are `ScrollView`s of
/// SwiftUI `Button`s, and a macOS button never becomes first responder, so
/// clicking a project row leaves the terminal holding the keyboard. Asking
/// AppKit who is focused therefore reports "a terminal" the whole time the
/// user is working in the file tree. The click itself is the only honest
/// signal of where their attention is.
enum PointerRegion {
    case content
    case interface
}

/// Tracks ``PointerRegion`` for the whole app, so a zoom keystroke can act on
/// whatever the user is looking at.
///
/// The question asked is "did this land in a sidebar", not "did this land in a
/// pane". Naming the two interface regions is a closed problem — there are
/// exactly two, and each reports the frame it occupies — whereas naming
/// everything that counts as pane content is open-ended: a pane's header, its
/// scrollers, a browser's toolbar, and the terminal's overlay scrollbar are
/// all chrome owned by a pane but living outside the view that draws it.
/// Asking this way round leaves anything unrecognized as `.content`, which is
/// where zoom has always gone.
@MainActor
final class PointerRegionTracker {
    static let shared = PointerRegionTracker()

    /// Content until the user says otherwise: panes are what a terminal
    /// workspace opens into, and zoom has always meant the terminal font.
    private(set) var region: PointerRegion = .content

    private var monitor: Any?
    /// Weakly held, so a closed window's sidebars cannot keep views alive and
    /// a collapsed sidebar drops out of the hierarchy on its own.
    private var interfaceRegions: [() -> NSView?] = []

    private init() {}

    /// Watches left mouse-downs app-wide. A local monitor sees the event
    /// before the view does and never consumes it, so this cannot disturb
    /// selection, dragging, or focus.
    ///
    /// Installed lazily and only once: re-creating the SwiftUI `App` value
    /// would otherwise stack a second monitor.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.record(event)
            }
            return event
        }
    }

    /// Called when a terminal, an editor, or a page takes the keyboard.
    ///
    /// Selecting a session in the sidebar is one gesture with two halves: the
    /// click lands in the interface, and the pane it selects then claims focus.
    /// Without this the region would stay `.interface` while the user types
    /// into the terminal they just chose, and zoom would resize the sidebar
    /// out from under them. Only a *transition* into content counts — a click
    /// on a sidebar button leaves focus where it already was, fires nothing,
    /// and so keeps the interface as the target.
    func contentTookFocus() {
        region = .content
    }

    func addInterfaceRegion(_ view: NSView) {
        interfaceRegions.append { [weak view] in view }
    }

    private func record(_ event: NSEvent) {
        guard let window = event.window,
              // The palette is a modal overlay and Settings is its own window:
              // clicking either is not the user turning to the interface, and
              // a palette row that runs Zoom would otherwise always land on it.
              WorkspaceWindows.isWorkspace(window),
              !WorkspaceWindows.isPaletteOpen(in: window)
        else { return }
        region = isInInterface(event.locationInWindow, of: window) ? .interface : .content
    }

    /// Whether a window-space point falls inside a sidebar that is on screen.
    private func isInInterface(_ point: NSPoint, of window: NSWindow) -> Bool {
        interfaceRegions.removeAll { $0() == nil }
        return interfaceRegions.contains { region in
            guard let view = region(),
                  view.window === window,
                  !view.isHiddenOrHasHiddenAncestor
            else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }
    }
}

/// Reports the frame of one of Terminal's sidebars to ``PointerRegionTracker``.
///
/// Attached as a `.background`, so it takes no part in layout and refuses hit
/// testing: it cannot change how the sidebar behaves, and the tracker only
/// reads the frame it occupies.
struct InterfaceRegionReporter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        RegionView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class RegionView: NSView {
        private var registered = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !registered, window != nil else { return }
            registered = true
            PointerRegionTracker.shared.addInterfaceRegion(self)
        }
    }
}

/// Which windows a click is allowed to speak for. Settings, the About panel,
/// and sheets are not places a zoom target is chosen, and the command palette
/// runs commands of its own that must act on the workspace behind it.
@MainActor
enum WorkspaceWindows {
    static func isWorkspace(_ window: NSWindow) -> Bool {
        TerminalManager.isWorkspaceWindow(window)
    }

    static func isPaletteOpen(in window: NSWindow) -> Bool {
        TerminalManager.isCommandPaletteVisible(in: window)
    }
}
