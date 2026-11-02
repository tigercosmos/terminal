//
//  KeroAgentRosterTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The roster row is how a user tells several agents apart at a glance, so a
/// blank label or alias must never win over a name that says something.
struct KeroAgentRosterTests {
    @Test func aLabelIsTrimmed() {
        #expect(KeroAgentRoster.normalizedLabel("  reviewer \n") == "reviewer")
        #expect(KeroAgentRoster.normalizedLabel("code review") == "code review")
    }

    /// Clearing the rename field must restore the default name rather than
    /// store an empty label that renders a nameless row.
    @Test func aBlankLabelIsNoLabel() {
        #expect(KeroAgentRoster.normalizedLabel("") == nil)
        #expect(KeroAgentRoster.normalizedLabel(" \t\n ") == nil)
    }

    @Test func theUsersLabelWinsOverTheAliasAndKind() {
        let name = KeroAgentRoster.displayName(
            customLabel: "reviewer", alias: "codex-2", kindName: "Codex"
        )
        #expect(name == "reviewer")
    }

    @Test func theAliasWinsOverTheKindWhenUnlabeled() {
        #expect(KeroAgentRoster.displayName(
            customLabel: nil, alias: "codex-2", kindName: "Codex"
        ) == "codex-2")
        #expect(KeroAgentRoster.displayName(
            customLabel: "   ", alias: "codex-2", kindName: "Codex"
        ) == "codex-2")
    }

    @Test func aWhitespaceAliasFallsThroughToTheKind() {
        #expect(KeroAgentRoster.displayName(
            customLabel: nil, alias: "  ", kindName: "Claude Code"
        ) == "Claude Code")
        #expect(KeroAgentRoster.displayName(
            customLabel: nil, alias: nil, kindName: "Claude Code"
        ) == "Claude Code")
    }
}
