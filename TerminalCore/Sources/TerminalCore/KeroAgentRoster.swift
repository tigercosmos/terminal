//
//  KeroAgentRoster.swift
//  TerminalCore
//

import Foundation

/// Naming rules for the sidebar's agent roster, kept apart from the view so
/// the precedence between a user's label and the automation alias is tested
/// without a window.
public nonisolated enum KeroAgentRoster {
    /// Normalizes a user-typed label: trims whitespace, collapses to nil when
    /// empty. A label is a user-authored name like `Project.customName`, not a
    /// terminal payload, so only surrounding whitespace is touched.
    public static func normalizedLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name a roster row shows: the user's label if set, else the
    /// automation alias, else the kind's display name. Each candidate is
    /// normalized first, so a blank alias falls through instead of rendering
    /// an empty row.
    public static func displayName(
        customLabel: String?,
        alias: String?,
        kindName: String
    ) -> String {
        customLabel.flatMap(normalizedLabel)
            ?? alias.flatMap(normalizedLabel)
            ?? kindName
    }
}
