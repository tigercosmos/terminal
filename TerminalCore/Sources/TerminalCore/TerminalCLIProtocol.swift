//
//  TerminalCLIProtocol.swift
//  TerminalCore
//

import CryptoKit
import Foundation

/// One request from the bundled `terminal` executable to its owning app.
///
/// Every field a handler acts on travels inside the signed body, so nothing the
/// app reads can be substituted by another poster. See ``TerminalCLIProtocol``.
public struct TerminalCLIRequest: Codable {
    public var action: String
    /// Distinguishes two otherwise identical requests, letting the app reject a
    /// replay of one it has already run.
    public var nonce: String
    /// Identifies one `+themes` invocation across its preview/save/cancel
    /// requests.
    public var id: String?
    /// The CLI process, so the app can restore the saved theme if it exits
    /// while a preview is live.
    public var pid: Int32?
    public var appearance: String?
    public var theme: String?
    public var arguments: [String]?
    public var directory: String?
    /// The invoking shell's `PATH`, so a command the CLI launches resolves the
    /// way it would have in the terminal it was typed in.
    public var path: String?

    /// Only the two fields every request carries; the rest are filled in by
    /// whichever CLI subcommand is building the request.
    public init(action: String, nonce: String) {
        self.action = action
        self.nonce = nonce
    }
}

/// Authenticates traffic between the `terminal` CLI and the app that launched it.
///
/// Distributed notifications reach every process running as this user, so the
/// per-launch secret is never placed in one. Instead the CLI sends a signed
/// body: an observer learns what a request contained but not the key, and so
/// cannot mint a different one. This matters because `openProject` carries an
/// argv the app executes — leaking the key would hand any observer arbitrary
/// command execution inside Terminal.
///
/// Against a process that can already read the CLI's environment this is not a
/// boundary, and it is not meant to be one: that process is running as the user
/// already. What it removes is the broadcast.
public enum TerminalCLIProtocol {
    /// The bundle the CLI and its owning app share. The `terminal` executable
    /// lives inside the app bundle, so both processes resolve the same value —
    /// and a Debug build resolves a different one from an installed Release
    /// build. The fallback covers a `terminal` invoked through a symlink
    /// outside any bundle, which can then still reach a release app.
    public static let bundleIdentifier =
        Bundle.main.bundleIdentifier ?? "com.github.tigercosmos.terminal"

    /// Namespaced per bundle, so a Debug build and an installed Release build
    /// never share a channel. Distributed notifications are matched by name
    /// across the whole user session, so an unqualified name let whichever app
    /// happened to be listening act on the other's requests.
    public static let notificationName = Notification.Name("\(bundleIdentifier).cli")

    /// Whether the CLI bridge in `environment` was issued by *this* bundle.
    ///
    /// Presence alone does not mean this process is the CLI: every Terminal
    /// shell exports these variables, they are inherited by everything that
    /// shell launches, and `open(1)` hands them to whatever app it starts. So
    /// `open`ing a Debug build from a shell inside a Release build used to make
    /// the Debug app take the CLI path, post its request to the Release app,
    /// and exit before ever showing a window.
    public static func bridgeTargetsThisBundle(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment["TERMINAL_CLI_STATE"]?.isEmpty == false,
              environment["TERMINAL_CLI_TOKEN"]?.isEmpty == false
        else { return false }
        return environment["TERMINAL_CLI_BUNDLE"] == bundleIdentifier
    }

    private static let bodyKey = "body"
    private static let macKey = "mac"

    /// Generous next to the app's own argv limits, and small enough that a
    /// malformed or hostile notification cannot make the app allocate.
    private static let maximumBodyBytes = 8 << 20

    public static func userInfo(
        for request: TerminalCLIRequest, secret: String
    ) -> [String: Any]? {
        guard let body = try? JSONEncoder().encode(request),
              body.count <= maximumBodyBytes
        else { return nil }
        return [
            bodyKey: body.base64EncodedString(),
            macKey: Data(authenticationCode(for: body, secret: secret))
                .base64EncodedString(),
        ]
    }

    /// Returns the request only if it was signed with `secret`. A body that
    /// fails verification is indistinguishable from noise and is dropped
    /// without being decoded.
    public static func request(
        from userInfo: [AnyHashable: Any]?, secret: String
    ) -> TerminalCLIRequest? {
        guard let encodedBody = userInfo?[bodyKey] as? String,
              let encodedMAC = userInfo?[macKey] as? String,
              let body = Data(base64Encoded: encodedBody),
              body.count <= maximumBodyBytes,
              let mac = Data(base64Encoded: encodedMAC)
        else { return nil }

        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        guard HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: body, using: key
        ) else { return nil }

        return try? JSONDecoder().decode(TerminalCLIRequest.self, from: body)
    }

    private static func authenticationCode(
        for body: Data, secret: String
    ) -> HMAC<SHA256>.MAC {
        // The secret is a UUID string rather than key material, so it is hashed
        // to a full-width key instead of being used as raw bytes.
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        return HMAC<SHA256>.authenticationCode(for: body, using: key)
    }
}

/// Remembers the nonces of recently handled requests so an observer cannot
/// replay one it captured. Bounded: the window only has to outlast the
/// notification traffic of a single CLI invocation.
public struct TerminalCLINonceWindow {
    private var seen: Set<String> = []
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 512) {
        self.limit = limit
    }

    /// Records `nonce` and reports whether it is the first time it was seen.
    public mutating func claim(_ nonce: String) -> Bool {
        guard seen.insert(nonce).inserted else { return false }
        order.append(nonce)
        if order.count > limit {
            seen.remove(order.removeFirst())
        }
        return true
    }
}
