//
//  CompareSidesTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The Git panel and the Compare panel both open the same two-column view, and
/// which version each column shows is decided entirely by these rev specs. A
/// wrong one does not fail — it quietly shows the wrong version of the file,
/// which is the worst way for a diff to be wrong.
struct CompareSidesTests {
    private let path = "Sources/App/main.swift"

    /// `HEAD:path` is the committed version and a bare `:path` is the staged
    /// one. Swapping them would show a staged diff as if nothing were staged.
    @Test func theGitPanelsCasesNameTheRightRevisions() {
        #expect(CompareSides.staged.baseSpec(path: path) == "HEAD:\(path)")
        #expect(CompareSides.staged.rightSpec(path: path) == ":\(path)")

        #expect(CompareSides.unstaged.baseSpec(path: path) == ":\(path)")
        // The right column is the file on disk, not a blob.
        #expect(CompareSides.unstaged.rightSpec(path: path) == nil)
    }

    /// A comparison the user asked for reads the commit it was pinned to, so a
    /// branch moving afterwards cannot change what an open tab shows.
    @Test func aRevisionComparisonReadsItsPinnedCommit() {
        let sides = CompareSides.revision(oid: "abc123", name: "origin/main")

        #expect(sides.baseSpec(path: path) == "abc123:\(path)")
        #expect(sides.rightSpec(path: path) == nil)
    }

    /// An untracked file exists nowhere but the working tree. Asking Git for a
    /// left side would only produce an error to show in place of the diff.
    @Test func anUntrackedFileHasNoLeftSide() {
        #expect(CompareSides.untracked.baseSpec(path: path) == nil)
        #expect(CompareSides.untracked.rightSpec(path: path) == nil)
    }

    /// Blame needs a commit. The index is not one, so offering blame there
    /// would attribute staged edits to whoever last touched those lines.
    @Test func onlyARevisionCanBeBlamed() {
        #expect(CompareSides.revision(oid: "abc123", name: "main").baseBlameRevision == "abc123")
        #expect(CompareSides.staged.baseBlameRevision == nil)
        #expect(CompareSides.unstaged.baseBlameRevision == nil)
        #expect(CompareSides.untracked.baseBlameRevision == nil)
    }

    /// Sessions saved before this was a comparison stored the stage side as
    /// two flags, and still do. A restored tab has to come back as the same
    /// diff it was.
    @Test func theSavedStageFlagsRoundTrip() {
        for sides in [CompareSides.staged, .unstaged, .untracked] {
            let restored = CompareSides(
                staged: sides.isStaged, untracked: sides.isUntracked
            )
            #expect(restored == sides)
        }
    }

    /// A rename reads the left column under the file's old name, or the whole
    /// file reads as new.
    @Test func theBaseSpecFollowsWhicheverPathItIsGiven() {
        let sides = CompareSides.revision(oid: "abc123", name: "main")

        #expect(sides.baseSpec(path: "old/name.swift") == "abc123:old/name.swift")
    }
}
