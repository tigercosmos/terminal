//
//  TerminalFind+Focus.swift
//  terminal
//

import AppKit
import TerminalCore

/// The one part of find that is about windows rather than about searching.
/// `TerminalFind` itself lives in `TerminalCore` and knows nothing of AppKit.
extension TerminalFind {
    /// Returns first responder to the terminal. Called once the find bar has
    /// actually left the view tree, because claiming it any earlier loses the
    /// race with SwiftUI tearing down the find field: AppKit resigns that
    /// field editor afterwards and the window is left without a first
    /// responder, so the terminal silently stops receiving keystrokes.
    func restoreTerminalFocus() {
        guard let view = surface as? NSView else { return }
        DispatchQueue.main.async {
            guard NSApp.isActive,
                  let window = view.window,
                  window.isKeyWindow,
                  window.firstResponder !== view
            else { return }
            window.makeFirstResponder(view)
        }
    }
}
