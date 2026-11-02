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

        case .pressKey:
            // `pressKey <characters> [repeats] [keyCode] [flags] [ignoring]`:
            // the last three let a driver hold a key that is not plain text
            // — an arrow, Backspace, Ctrl-d, Shift-J — by naming the virtual
            // key, a comma list of shift/control/option, and the characters
            // the key gives without modifiers, the way AppKit fills them in.
            guard let characters = request.arguments?.first, !characters.isEmpty else {
                return .failure("pressKey needs the key's characters")
            }
            let extra = Array(request.arguments?.dropFirst() ?? [])
            let repeats = extra.first.flatMap(Int.init) ?? 0
            guard repeats >= 0 else {
                return .failure("pressKey repeats must not be negative")
            }
            let keyCode = extra.dropFirst().first.flatMap(UInt16.init) ?? Self.keyCode(for: characters)
            var flags: NSEvent.ModifierFlags = []
            for name in extra.dropFirst(2).first?.split(separator: ",") ?? [] {
                switch name {
                case "shift": flags.insert(.shift)
                case "control": flags.insert(.control)
                case "option": flags.insert(.option)
                default: return .failure("unknown modifier “\(name)”")
                }
            }
            if Self.functionKeyCodes.contains(keyCode) { flags.insert(.function) }
            let ignoring = extra.dropFirst(3).first ?? characters
            guard let surface = focusedSurface(), let window = surface.window else {
                return .failure("no terminal is focused")
            }
            // The driver's shell is not trusted to post events, so the
            // events are made here and handed to the window, which routes
            // them to its first responder exactly as a real press would be.
            // The pane has to be that responder: a driver's window was never
            // clicked, and a pane opened a moment ago may not have taken
            // focus on its own.
            if let responder = window.firstResponder as? NSView,
               responder.isDescendant(of: surface) {
                // The pane already has the keyboard.
            } else {
                window.makeFirstResponder(surface)
            }
            func event(_ type: NSEvent.EventType, isARepeat: Bool) -> NSEvent? {
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: ignoring,
                    isARepeat: isARepeat, keyCode: keyCode
                )
            }
            // Spaced like the real thing rather than sent in one burst: the
            // input context's press-and-hold decision runs on timers, and a
            // burst with no run-loop turn between events would not reach it.
            var schedule: [(after: TimeInterval, event: NSEvent?)] = [(0, event(.keyDown, isARepeat: false))]
            var elapsed = NSEvent.keyRepeatDelay
            for _ in 0..<repeats {
                schedule.append((elapsed, event(.keyDown, isARepeat: true)))
                elapsed += NSEvent.keyRepeatInterval
            }
            schedule.append((elapsed, event(.keyUp, isARepeat: false)))
            for (after, event) in schedule {
                guard let event else { return .failure("the key event could not be made") }
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    window.sendEvent(event)
                }
            }
            return .success(String(format: "%.2f", elapsed))

        case .snapshotWindow:
            guard let path = request.arguments?.first else {
                return .failure("snapshotWindow needs a file path")
            }
            // The same workspace `queryState` answers for, never a Settings
            // or About window that happens to be key.
            guard let view = TerminalManager.keyWindowManager?.automationContentView else {
                return .failure("no window is open")
            }
            // The window's own drawing, not a screen grab: nothing is read
            // from the display, so no TCC prompt and no permission to lose.
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return .failure("the window could not be rendered")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                return .failure("the rendering could not be encoded")
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
            } catch {
                return .failure("the snapshot could not be written: \(error.localizedDescription)")
            }
            return .success(path)
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

    /// The US-layout virtual key for a character `pressKey` types. Only the
    /// special keys in `AlacrittyKeyMap` read the code; a letter is encoded
    /// from its characters, so an unknown character gets a code no key owns.
    private static func keyCode(for characters: String) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
            "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
            "m": 46, " ": 49, "\r": 36, "\t": 48, "\u{1b}": 53, "\u{7f}": 51,
        ]
        return characters.first.flatMap { codes[$0] } ?? 0xFFFF
    }

    /// Keys AppKit marks with `.function`: arrows, paging, Home/End, and
    /// forward delete. `AlacrittyKeyMap` does not read the flag, but a real
    /// event carries it, so the synthesized one does too.
    private static let functionKeyCodes: Set<UInt16> = [
        123, 124, 125, 126, 115, 119, 116, 121, 117,
    ]

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
