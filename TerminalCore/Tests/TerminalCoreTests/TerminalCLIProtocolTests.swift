//
//  TerminalCLIProtocolTests.swift
//  TerminalCore
//

import CryptoKit
import Foundation
import Testing

@testable import TerminalCore

/// The CLI channel is a broadcast: every process running as this user sees the
/// notification, and `openProject` carries an argv the app executes. These
/// tests cover what stops an observer from turning that into command execution
/// inside Terminal — the signature, the replay window, and the size ceiling.
struct TerminalCLIProtocolTests {
    private let secret = "5F1B9E0C-0000-4000-8000-000000000001"

    private func request(action: String = "openProject") -> TerminalCLIRequest {
        var request = TerminalCLIRequest(action: action, nonce: UUID().uuidString)
        request.arguments = ["--flag", "value"]
        request.directory = "/tmp/project"
        request.path = "/usr/bin:/bin"
        return request
    }

    @Test func signedRequestSurvivesTheRoundTrip() throws {
        let sent = request()
        let userInfo = try #require(
            TerminalCLIProtocol.userInfo(for: sent, secret: secret)
        )
        let received = try #require(
            TerminalCLIProtocol.request(from: userInfo, secret: secret)
        )
        #expect(received.action == sent.action)
        #expect(received.nonce == sent.nonce)
        #expect(received.arguments == sent.arguments)
        #expect(received.directory == sent.directory)
        #expect(received.path == sent.path)
    }

    @Test func theSecretItselfIsNeverBroadcast() throws {
        let userInfo = try #require(
            TerminalCLIProtocol.userInfo(for: request(), secret: secret)
        )
        for value in userInfo.values {
            #expect((value as? String)?.contains(secret) != true)
        }
    }

    @Test func aRequestSignedWithAnotherSecretIsRejected() throws {
        let userInfo = try #require(
            TerminalCLIProtocol.userInfo(for: request(), secret: "other-secret")
        )
        #expect(TerminalCLIProtocol.request(from: userInfo, secret: secret) == nil)
    }

    /// The body is what the app acts on, so swapping it for another app's
    /// signed body — or for one an observer wrote — must not verify.
    @Test func aSubstitutedBodyIsRejected() throws {
        var userInfo = try #require(
            TerminalCLIProtocol.userInfo(for: request(), secret: secret)
        )
        var forged = TerminalCLIRequest(action: "openProject", nonce: UUID().uuidString)
        forged.arguments = ["/bin/sh", "-c", "touch /tmp/pwned"]
        let body = try JSONEncoder().encode(forged)
        userInfo["body"] = body.base64EncodedString()
        #expect(TerminalCLIProtocol.request(from: userInfo, secret: secret) == nil)
    }

    @Test func aTamperedMACIsRejected() throws {
        var userInfo = try #require(
            TerminalCLIProtocol.userInfo(for: request(), secret: secret)
        )
        var mac = try #require(Data(base64Encoded: userInfo["mac"] as? String ?? ""))
        mac[0] ^= 0x01
        userInfo["mac"] = mac.base64EncodedString()
        #expect(TerminalCLIProtocol.request(from: userInfo, secret: secret) == nil)
    }

    @Test func malformedUserInfoIsDropped() {
        let malformed: [[String: Any]] = [
            [:],
            ["body": "not base64 %%%"],
            ["mac": "AAAA"],
            ["body": 42, "mac": "AAAA"],
            ["body": "AAAA", "mac": "not base64 %%%"],
        ]
        for userInfo in malformed {
            #expect(TerminalCLIProtocol.request(from: userInfo, secret: secret) == nil)
        }
        #expect(TerminalCLIProtocol.request(from: nil, secret: secret) == nil)
    }

    /// The ceiling exists so a hostile notification cannot make the app
    /// allocate; it has to be enforced before the base64 body is decoded as
    /// well as when one is signed.
    @Test func anOversizedBodyIsRefusedOnBothSides() throws {
        var huge = TerminalCLIRequest(action: "openProject", nonce: UUID().uuidString)
        huge.arguments = [String(repeating: "a", count: 9 << 20)]
        #expect(TerminalCLIProtocol.userInfo(for: huge, secret: secret) == nil)

        let body = try JSONEncoder().encode(huge)
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        let mac = Data(HMAC<SHA256>.authenticationCode(for: body, using: key))
        let userInfo: [String: Any] = [
            "body": body.base64EncodedString(),
            "mac": mac.base64EncodedString(),
        ]
        #expect(TerminalCLIProtocol.request(from: userInfo, secret: secret) == nil)
    }

    /// Presence of the bridge variables says a Terminal shell is somewhere in
    /// this process's ancestry, not that this process is the CLI. Only the
    /// bundle they name decides that; see `bridgeTargetsThisBundle`.
    @Test func onlyThisBundlesBridgeIsAccepted() {
        let complete = [
            "TERMINAL_CLI_STATE": "/tmp/state",
            "TERMINAL_CLI_TOKEN": "token",
            "TERMINAL_CLI_BUNDLE": TerminalCLIProtocol.bundleIdentifier,
        ]
        #expect(TerminalCLIProtocol.bridgeTargetsThisBundle(complete))

        var otherBundle = complete
        otherBundle["TERMINAL_CLI_BUNDLE"] = TerminalCLIProtocol.bundleIdentifier + ".other"
        #expect(!TerminalCLIProtocol.bridgeTargetsThisBundle(otherBundle))

        var noBundle = complete
        noBundle["TERMINAL_CLI_BUNDLE"] = nil
        #expect(!TerminalCLIProtocol.bridgeTargetsThisBundle(noBundle))

        for key in ["TERMINAL_CLI_STATE", "TERMINAL_CLI_TOKEN"] {
            var empty = complete
            empty[key] = ""
            #expect(!TerminalCLIProtocol.bridgeTargetsThisBundle(empty))
            var absent = complete
            absent[key] = nil
            #expect(!TerminalCLIProtocol.bridgeTargetsThisBundle(absent))
        }
    }
}

struct TerminalCLINonceWindowTests {
    @Test func aNonceIsClaimedOnceAndThenRefused() {
        var window = TerminalCLINonceWindow()
        #expect(claimed("a", from: &window))
        #expect(!claimed("a", from: &window))
        #expect(claimed("b", from: &window))
        #expect(!claimed("b", from: &window))
    }

    /// The window is bounded so a long-running app cannot be made to grow one
    /// nonce at a time. Everything still inside it stays refused.
    @Test func theWindowForgetsOnlyItsOldestNonces() {
        var window = TerminalCLINonceWindow(limit: 4)
        for nonce in ["a", "b", "c", "d"] {
            #expect(claimed(nonce, from: &window))
        }
        #expect(!claimed("d", from: &window))
        // The fifth claim drops the oldest nonce, "a".
        #expect(claimed("e", from: &window))
        for nonce in ["b", "c", "d", "e"] {
            #expect(!claimed(nonce, from: &window))
        }
        #expect(claimed("a", from: &window))
    }

    /// `claim` is mutating, which `#expect` cannot call on its own.
    private func claimed(
        _ nonce: String, from window: inout TerminalCLINonceWindow
    ) -> Bool {
        window.claim(nonce)
    }
}
