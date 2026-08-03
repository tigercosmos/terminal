//
//  TerminalCLIAutomationTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The automation surface drives the real UI, so what stops it from being
/// reachable matters as much as what it can do: it is compiled out of release
/// builds and dormant in a debug build nobody armed.
struct TerminalCLIAutomationTests {
    @Test func automationIsOffUntilItIsExplicitlyArmed() {
        #expect(TerminalCLIAutomation.isEnabled(["TERMINAL_AUTOMATION": "1"]))
        #expect(!TerminalCLIAutomation.isEnabled([:]))
        #expect(!TerminalCLIAutomation.isEnabled(["TERMINAL_AUTOMATION": ""]))
        #expect(!TerminalCLIAutomation.isEnabled(["TERMINAL_AUTOMATION": "0"]))
        // Anything other than exactly "1" leaves it off — "true" and "yes" are
        // the spellings someone reaches for by accident.
        #expect(!TerminalCLIAutomation.isEnabled(["TERMINAL_AUTOMATION": "true"]))
    }

    /// Only the actions the app deliberately offers exist; a request asking for
    /// anything else is not an automation request at all, and falls through to
    /// the ordinary handler.
    @Test func onlyTheKnownActionsAreRecognized() {
        #expect(TerminalCLIAutomationAction(action: "automation.sendText") == .sendText)
        #expect(TerminalCLIAutomationAction(action: "automation.queryState") == .queryState)
        #expect(TerminalCLIAutomationAction(action: "openProject") == nil)
        #expect(TerminalCLIAutomationAction(action: "automation.eval") == nil)
        #expect(TerminalCLIAutomationAction(action: "") == nil)
        // Namespaced, so an automation action can never collide with one of
        // the ordinary CLI's.
        #expect(TerminalCLIAutomationAction.allCases.allSatisfy {
            $0.rawValue.hasPrefix("automation.")
        })
    }

    // MARK: - The reply file

    private func stateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("themes.json")
    }

    @Test func aReplyIsWrittenBesideTheStateFileAndReadBack() throws {
        let state = try stateURL()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }

        let nonce = UUID().uuidString
        let url = try #require(
            TerminalCLIAutomation.replyURL(stateURL: state, nonce: nonce)
        )
        #expect(url.deletingLastPathComponent() == state.deletingLastPathComponent())

        try TerminalCLIAutomation.write(.success("hello"), to: url)
        let reply = try #require(TerminalCLIAutomation.read(at: url))
        #expect(reply.ok)
        #expect(reply.text == "hello")
        #expect(reply.error == nil)
    }

    /// A reply can hold a terminal's whole screen — keys and tokens included —
    /// so it is no more readable than the theme catalog beside it.
    @Test func aReplyIsWrittenReadableOnlyByItsOwner() throws {
        let state = try stateURL()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = try #require(
            TerminalCLIAutomation.replyURL(stateURL: state, nonce: UUID().uuidString)
        )
        try TerminalCLIAutomation.write(.success("secret"), to: url)
        let permissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
    }

    /// The reply path is derived from the state directory the app made, and
    /// the nonce is the only part a request contributes — so a nonce that is
    /// not a plain UUID must not be able to name a file elsewhere.
    @Test func aNonceCannotNameAFileOutsideTheStateDirectory() throws {
        let state = try stateURL()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }

        for nonce in [
            "../../escape", "..", "/etc/passwd", "a/b", "", "nonce with spaces",
        ] {
            #expect(
                TerminalCLIAutomation.replyURL(stateURL: state, nonce: nonce) == nil,
                "\(nonce) should not have named a reply file"
            )
        }
    }

    @Test func aFailureCarriesItsReasonAndNoAnswer() throws {
        let state = try stateURL()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = try #require(
            TerminalCLIAutomation.replyURL(stateURL: state, nonce: UUID().uuidString)
        )
        try TerminalCLIAutomation.write(.failure("no terminal is focused"), to: url)
        let reply = try #require(TerminalCLIAutomation.read(at: url))
        #expect(!reply.ok)
        #expect(reply.error == "no terminal is focused")
        #expect(reply.text == nil)
    }

    /// A reply that is not there yet, or is half-written, is not an answer —
    /// the CLI keeps waiting rather than reading a truncated file as a result.
    @Test func anAbsentOrUnreadableReplyIsNoAnswer() throws {
        let state = try stateURL()
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let url = try #require(
            TerminalCLIAutomation.replyURL(stateURL: state, nonce: UUID().uuidString)
        )
        #expect(TerminalCLIAutomation.read(at: url) == nil)

        try Data("{ not json".utf8).write(to: url)
        #expect(TerminalCLIAutomation.read(at: url) == nil)
    }
}
