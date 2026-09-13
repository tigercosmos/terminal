//
//  TerminalCLIService+Automation.swift
//  terminal
//

#if DEBUG

import AppKit
import Foundation
import TerminalCore

/// The debug-only half of the CLI channel: driving the running app from
/// outside it, so a feature can be checked without capturing the screen or
/// synthesizing keystrokes.
///
/// Everything here is behind `#if DEBUG` *and* `TERMINAL_AUTOMATION=1` on the
/// app's launch. See ``TerminalCLIAutomation`` for why both.
///
/// The failure messages are deliberately not localized: they are read by
/// whoever is running the driver, never by a user of the app, and putting them
/// in the catalog would put developer text in front of translators.
extension TerminalCLIService {
    /// Handles `request` if it is an automation request, and says whether it
    /// did. Called from the ordinary request handler, after the signature and
    /// the nonce have already been checked.
    func handleAutomation(_ request: TerminalCLIRequest) -> Bool {
        guard let action = TerminalCLIAutomationAction(action: request.action) else {
            return false
        }
        guard TerminalCLIAutomation.isEnabled() else {
            reply(.failure("Terminal was not launched with TERMINAL_AUTOMATION=1"),
                  to: request)
            return true
        }
        // A background launch has no window until one is asked for; the
        // driver polls `queryState` until this stops failing.
        if TerminalManager.keyWindowManager == nil {
            TerminalManager.openWindowForAutomation()
            reply(.failure("no window is open yet"), to: request)
            return true
        }
        reply(perform(action, request), to: request)
        return true
    }

    private func perform(
        _ action: TerminalCLIAutomationAction, _ request: TerminalCLIRequest
    ) -> TerminalCLIReply {
        switch action {
        case .sendText:
            guard let text = request.arguments?.first else {
                return .failure("sendText needs text")
            }
            guard let surface = focusedSurface() else {
                return .failure("no terminal is focused")
            }
            // A driver sends a command to be run, not pasted, so this is the
            // typed path — the two backends otherwise disagree about whether a
            // trailing newline submits.
            surface.sendTypedText(text)
            return .success()

        case .paste:
            guard let surface = focusedSurface() else {
                return .failure("no terminal is focused")
            }
            guard let responder = Self.pasteResponder(in: surface) else {
                return .failure("the focused terminal accepted no paste")
            }
            responder.perform(#selector(NSText.paste(_:)), with: nil)
            return .success()

        case .readScreen, .readScrollback:
            guard let surface = focusedSurface() else {
                return .failure("no terminal is focused")
            }
            let path = action == .readScreen
                ? surface.exportScreenFile() : surface.exportScrollbackFile()
            guard let capture = TerminalCaptureFile.validated(for: path) else {
                // A backend exports nothing for an empty scrollback, and
                // nothing while an alternate buffer is up.
                return .success("")
            }
            defer { capture.remove() }
            guard let text = try? String(contentsOf: capture.fileURL, encoding: .utf8)
            else { return .failure("the export could not be read") }
            return .success(text)

        case .runCommand:
            guard let identifier = request.arguments?.first else {
                return .failure("runCommand needs a command identifier")
            }
            guard let manager = TerminalManager.keyWindowManager else {
                return .failure("no window is open")
            }
            // The palette's own table, so an automation action cannot drift
            // from the command the user would have run.
            guard let command = paletteCommands(manager: manager)
                .first(where: { $0.id == identifier })
            else { return .failure("no command with the identifier “\(identifier)”") }
            command.action()
            return .success()

        case .queryState:
            guard let manager = TerminalManager.keyWindowManager else {
                return .failure("no window is open")
            }
            // The session snapshot, rather than a shape invented for tests:
            // asserting on what the app already persists keeps the two from
            // describing the window differently.
            let snapshot = manager.automationSnapshot()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? encoder.encode(snapshot) else {
                return .failure("the window state could not be encoded")
            }
            return .success(String(decoding: data, as: UTF8.self))
        }
    }

    /// Leaves the bridge a driver script needs, when the app was armed.
    /// See ``TerminalCLIAutomation/Bridge``.
    func writeAutomationBridge() {
        guard TerminalCLIAutomation.isEnabled() else { return }
        let bridge = TerminalCLIAutomation.Bridge(
            state: stateURL.path,
            token: secret,
            bundle: TerminalCLIProtocol.bundleIdentifier
        )
        do {
            try TerminalCLIAutomation.write(
                bridge, to: TerminalCLIAutomation.bridgeURL(stateURL: stateURL)
            )
        } catch {
            NSLog("terminal: failed to write the automation bridge: \(error)")
        }
    }

    /// The view inside `surface` that implements `paste(_:)` — the backend's
    /// own paste, so a driver's paste goes through whatever it decides to
    /// confirm first, exactly as Cmd-V does.
    ///
    /// Searched inside the surface rather than sent through `NSApp` or walked
    /// up from the window's first responder. `NSApp` only has a target while
    /// Terminal is active, and a driver runs with its own shell in front; the
    /// window's first responder is the window itself for as long as a pane
    /// opened a moment ago has yet to take focus, and nothing above a window
    /// pastes. Both made the action depend on timing the driver cannot see.
    /// Which view answers is still the backend's choice: the Alacritty
    /// surface pastes itself, libghostty's is a subview of ours.
    private static func pasteResponder(in surface: NSView) -> NSResponder? {
        if surface.responds(to: #selector(NSText.paste(_:))) { return surface }
        for subview in surface.subviews {
            if let responder = pasteResponder(in: subview) { return responder }
        }
        return nil
    }

    private func focusedSurface() -> (any TerminalBackendSurface)? {
        TerminalManager.keyWindowManager?.selectedSession?.surface
    }

    private func reply(_ reply: TerminalCLIReply, to request: TerminalCLIRequest) {
        guard let url = TerminalCLIAutomation.replyURL(
            stateURL: stateURL, nonce: request.nonce
        ) else { return }
        do {
            try TerminalCLIAutomation.write(reply, to: url)
        } catch {
            NSLog("terminal: failed to write the automation reply: \(error)")
        }
    }
}

#endif
