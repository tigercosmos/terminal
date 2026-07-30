//
//  KeroCLIProtocol.swift
//  kero
//

import CryptoKit
import Foundation

/// One request from the bundled `kero` executable to its owning app.
///
/// Every field a handler acts on travels inside the signed body, so nothing the
/// app reads can be substituted by another poster. See ``KeroCLIProtocol``.
struct KeroCLIRequest: Codable {
    var action: String
    /// Distinguishes two otherwise identical requests, letting the app reject a
    /// replay of one it has already run.
    var nonce: String
    /// Identifies one `+themes` invocation across its preview/save/cancel
    /// requests.
    var id: String?
    /// The CLI process, so the app can restore the saved theme if it exits
    /// while a preview is live.
    var pid: Int32?
    var appearance: String?
    var theme: String?
    var arguments: [String]?
    var directory: String?
    /// The invoking shell's `PATH`, so a command the CLI launches resolves the
    /// way it would have in the terminal it was typed in.
    var path: String?
}

/// Authenticates traffic between the `kero` CLI and the app that launched it.
///
/// Distributed notifications reach every process running as this user, so the
/// per-launch secret is never placed in one. Instead the CLI sends a signed
/// body: an observer learns what a request contained but not the key, and so
/// cannot mint a different one. This matters because `openProject` carries an
/// argv the app executes — leaking the key would hand any observer arbitrary
/// command execution inside Kero.
///
/// Against a process that can already read the CLI's environment this is not a
/// boundary, and it is not meant to be one: that process is running as the user
/// already. What it removes is the broadcast.
enum KeroCLIProtocol {
    static let notificationName = Notification.Name("sh.kero.cli")

    private static let bodyKey = "body"
    private static let macKey = "mac"

    /// Generous next to the app's own argv limits, and small enough that a
    /// malformed or hostile notification cannot make the app allocate.
    private static let maximumBodyBytes = 8 << 20

    static func userInfo(
        for request: KeroCLIRequest, secret: String
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
    static func request(
        from userInfo: [AnyHashable: Any]?, secret: String
    ) -> KeroCLIRequest? {
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

        return try? JSONDecoder().decode(KeroCLIRequest.self, from: body)
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
struct KeroCLINonceWindow {
    private var seen: Set<String> = []
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = limit
    }

    /// Records `nonce` and reports whether it is the first time it was seen.
    mutating func claim(_ nonce: String) -> Bool {
        guard seen.insert(nonce).inserted else { return false }
        order.append(nonce)
        if order.count > limit {
            seen.remove(order.removeFirst())
        }
        return true
    }
}
