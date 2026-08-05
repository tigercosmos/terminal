//
//  CompareSides.swift
//  TerminalCore
//

import Foundation

/// What the two columns of a side-by-side comparison read.
///
/// One shape serves both entry points, because they are the same question
/// asked of different revisions: ⌘⇧C compares the working tree against a
/// branch or commit the user picked, and the Git panel compares it against
/// HEAD and the index. Each case names a Git rev spec for the left column and,
/// where the right is not the live file, one for that too.
///
/// Lives here rather than beside the view so the spec arithmetic — which is
/// the part that silently shows the wrong version if it is wrong — can be
/// tested without a window.
public enum CompareSides: Equatable, Sendable {
    /// A revision the user picked, against the working tree.
    case revision(oid: String, name: String)
    /// The index against the working tree — the Git panel's unstaged rows.
    case unstaged
    /// HEAD against the index — the Git panel's staged rows.
    ///
    /// The one case with no live file in it. `git add` snapshotted the file,
    /// so neither side is what is on disk, and showing the working tree on the
    /// right would quietly fold unstaged edits into a view of what is staged.
    case staged
    /// Nothing against the working tree — an untracked file, entirely new.
    case untracked

    /// The rev spec the left column reads, or nil for a side with no content
    /// at all: an untracked file never existed anywhere to be read from.
    public func baseSpec(path: String) -> String? {
        switch self {
        case .revision(let oid, _): "\(oid):\(path)"
        // A bare `:path` is the index entry — Git's own syntax for it.
        case .unstaged: ":\(path)"
        case .staged: "HEAD:\(path)"
        case .untracked: nil
        }
    }

    /// The rev spec the right column reads instead of the file on disk, or nil
    /// to use the live file.
    public func rightSpec(path: String) -> String? {
        if case .staged = self { return ":\(path)" }
        return nil
    }

    /// The commit the left column can be blamed at, or nil where blame would
    /// lie. Only a comparison against a real revision qualifies: the index is
    /// not a commit, and blaming HEAD in its place would attribute staged
    /// edits to whoever last touched those lines.
    public var baseBlameRevision: String? {
        if case .revision(let oid, _) = self { return oid }
        return nil
    }

    /// The session snapshot has recorded the Git panel's stage side as these
    /// two flags since before this was a comparison, and older saved sessions
    /// still hold them that way.
    public var isStaged: Bool { self == .staged }
    public var isUntracked: Bool { self == .untracked }

    /// Rebuilds a case from the flags a saved session stored.
    public init(staged: Bool, untracked: Bool) {
        self = untracked ? .untracked : (staged ? .staged : .unstaged)
    }
}
