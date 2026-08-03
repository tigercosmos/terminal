//
//  TerminalCLIAutomation.swift
//  TerminalCore
//

#if DEBUG

import Foundation

/// Driving a running Terminal from outside it, over the channel the `terminal`
/// CLI already uses.
///
/// This exists so a feature can be checked without capturing the screen or
/// synthesizing keystrokes — both of which need a TCC grant that an unsigned
/// debug build loses on every rebuild. The app injects its own input and
/// reports its own state, so neither permission is ever requested.
///
/// Compiled only into debug builds, *and* switched off unless the app was
/// launched with `TERMINAL_AUTOMATION=1`. A release build carries none of it,
/// and a debug build a developer is simply using carries it dormant: the
/// actions below drive the real UI, so an observer who could reach them would
/// be typing into the user's shells.
public enum TerminalCLIAutomation {
    /// Set on the app's launch environment to arm the actions below.
    public static let environmentKey = "TERMINAL_AUTOMATION"

    public static func isEnabled(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Where the app leaves the answer to a request.
    ///
    /// Derived from the state directory the app itself created — never sent in
    /// the request. A path that travelled in the body would be a path the app
    /// writes to on someone else's say-so, and the point of signing the body
    /// is that the app only ever acts on its own terms.
    public static func replyURL(stateURL: URL, nonce: String) -> URL? {
        // The nonce reaches this from a signed request, but it still names a
        // file: a nonce that was not a plain UUID could otherwise walk out of
        // the directory the app owns.
        guard UUID(uuidString: nonce) != nil else { return nil }
        return stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("reply-\(nonce).json")
    }

    /// The file an armed app leaves so a driver that is *not* running inside
    /// one of its shells can still reach it.
    ///
    /// A shell Terminal starts inherits the bridge in its environment; a script
    /// run from anywhere else does not, and the per-launch secret exists
    /// nowhere else. Handing it over in the app's own 0700 directory is what
    /// makes this layer usable from a script at all, and it gives away no more
    /// than the environment of any shell the app already started — the boundary
    /// the signing exists for is the broadcast, not a process already running
    /// as this user. Written only when armed, and only in a debug build.
    public struct Bridge: Codable, Equatable, Sendable {
        public var state: String
        public var token: String
        public var bundle: String

        public init(state: String, token: String, bundle: String) {
            self.state = state
            self.token = token
            self.bundle = bundle
        }

        /// The environment a driver has to export for `terminal` to reach this
        /// app — the same three variables its own shells carry.
        public var environment: [String: String] {
            [
                "TERMINAL_CLI_STATE": state,
                "TERMINAL_CLI_TOKEN": token,
                "TERMINAL_CLI_BUNDLE": bundle,
            ]
        }
    }

    public static func bridgeURL(stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("automation.json")
    }

    public static func write(_ bridge: Bridge, to url: URL) throws {
        try JSONEncoder().encode(bridge).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    public static func write(_ reply: TerminalCLIReply, to url: URL) throws {
        let data = try JSONEncoder().encode(reply)
        try data.write(to: url, options: .atomic)
        // The reply can hold a terminal's whole screen — keys and tokens
        // included — so it gets the same treatment the theme catalog does.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    public static func read(at url: URL) -> TerminalCLIReply? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TerminalCLIReply.self, from: data)
    }
}

/// One automation request's action, parsed from the signed body.
///
/// A closed set rather than a free-form string, so a request can only ask for
/// something the app deliberately offers.
public enum TerminalCLIAutomationAction: String, CaseIterable, Sendable {
    /// Feed input to the focused surface, as though it had been typed. Uses
    /// the backend's own `sendText`, so no Accessibility grant is involved.
    case sendText = "automation.sendText"
    /// The visible grid, as text.
    case readScreen = "automation.readScreen"
    /// The scrollback, as text.
    case readScrollback = "automation.readScrollback"
    /// Run a command-palette action by its identifier.
    case runCommand = "automation.runCommand"
    /// The model-layer state a test wants to assert on, as the same JSON a
    /// saved session is written in.
    case queryState = "automation.queryState"

    public init?(action: String) {
        self.init(rawValue: action)
    }
}

/// What the app leaves for the CLI to read.
public struct TerminalCLIReply: Codable, Equatable, Sendable {
    public var ok: Bool
    /// The answer, for an action that has one.
    public var text: String?
    /// Why it failed, for one that did not.
    public var error: String?

    public init(ok: Bool, text: String? = nil, error: String? = nil) {
        self.ok = ok
        self.text = text
        self.error = error
    }

    public static func success(_ text: String? = nil) -> TerminalCLIReply {
        TerminalCLIReply(ok: true, text: text)
    }

    public static func failure(_ error: String) -> TerminalCLIReply {
        TerminalCLIReply(ok: false, error: error)
    }
}

#endif
