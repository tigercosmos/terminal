//
//  TerminalCursorSettings.swift
//  terminal
//

import Foundation
import GhosttyTerminal

/// The cursor a terminal shows before a program picks one for itself.
///
/// This is the *default* only: DECSCUSR still wins, so a TUI that asks for a
/// bar keeps it while this setting says block. Both backends are given the
/// same choice, in the shape each one takes it — Ghostty by config key, the
/// Alacritty bridge by a small integer over the C boundary.
enum TerminalCursorShape: String, CaseIterable, Sendable {
    case block
    case bar
    case underline

    var title: String {
        switch self {
        case .block: String(localized: "Block")
        case .bar:
            String(
                localized: "Bar",
                comment: "A thin vertical terminal cursor, as opposed to a block."
            )
        case .underline: String(localized: "Underline")
        }
    }

    var ghosttyValue: TerminalCursorStyle {
        switch self {
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        }
    }

    /// Matches `configured_cursor_style` in the bridge; the two have to agree.
    var alacrittyValue: UInt8 {
        switch self {
        case .block: 0
        case .underline: 1
        case .bar: 2
        }
    }
}
