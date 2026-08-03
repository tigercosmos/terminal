//
//  CompareDiffTests.swift
//  TerminalCore
//

import Testing

@testable import TerminalCore

/// The comparison view never pads either column with filler text, so the whole
/// alignment is carried by gap counts and line indices. A wrong gap is a
/// side-by-side diff whose rows do not line up, which is only visible by eye —
/// these tests are what makes it visible without one.
struct CompareDiffTests {
    @Test func aLineIndexHereIsTheLineIndexTheGutterNumbers() {
        #expect(CompareDiff.lines("a\nb\nc") == ["a", "b", "c"])
        // A trailing newline leaves a final empty line, exactly as the editor
        // lays the text out.
        #expect(CompareDiff.lines("a\n") == ["a", ""])
        #expect(CompareDiff.lines("") == [""])
    }

    @Test func lineStartOffsetsCountTheSeparatingNewline() {
        #expect(CompareDiff.lineStartOffsets(["ab", "c", ""]) == [0, 3, 5])
        #expect(CompareDiff.lineStartOffsets([]) == [])
    }

    /// UTF-16 offsets, not character counts: the offsets map a text view's
    /// layout position back to a line, and the text view counts UTF-16.
    @Test func lineStartOffsetsCountUTF16Units() {
        // "🙂" is a surrogate pair — two UTF-16 units — so the next line starts
        // at 3, not 2.
        #expect(CompareDiff.lineStartOffsets(["🙂", "x"]) == [0, 3])
    }

    @Test func identicalSidesHaveNoGapsAndNoChanges() {
        let alignment = CompareDiff.align(old: ["a", "b"], new: ["a", "b"])
        #expect(alignment == CompareAlignment())
        #expect(!alignment.hasChanges)
    }

    /// A removal has nothing on the new side to pair with, so the new column
    /// gets a blank row before whatever follows the removed line.
    @Test func aRemovedLinePushesTheNewColumnDown() {
        let alignment = CompareDiff.align(old: ["a", "b", "c"], new: ["a", "c"])
        #expect(alignment.removedLines == [1])
        #expect(alignment.addedLines == [])
        #expect(alignment.newGaps == [1: 1])
        #expect(alignment.oldGaps.isEmpty)
        #expect(alignment.hasChanges)
    }

    @Test func anAddedLinePushesTheOldColumnDown() {
        let alignment = CompareDiff.align(old: ["a", "c"], new: ["a", "b", "c"])
        #expect(alignment.addedLines == [1])
        #expect(alignment.removedLines == [])
        #expect(alignment.oldGaps == [1: 1])
        #expect(alignment.newGaps.isEmpty)
    }

    /// A replacement is a removal run and an insertion run in the same block.
    /// Equal-length runs sit on the same rows, so neither column needs a gap.
    @Test func anEqualLengthReplacementNeedsNoGaps() {
        let alignment = CompareDiff.align(old: ["a", "x", "c"], new: ["a", "y", "c"])
        #expect(alignment.removedLines == [1])
        #expect(alignment.addedLines == [1])
        #expect(alignment.oldGaps.isEmpty)
        #expect(alignment.newGaps.isEmpty)
    }

    /// Only the surplus is levelled: three lines replaced by one leaves two
    /// blank rows on the new side, not three.
    @Test func onlyTheSurplusOfAChangeBlockBecomesAGap() {
        let alignment = CompareDiff.align(
            old: ["a", "x", "y", "z", "c"], new: ["a", "w", "c"]
        )
        #expect(alignment.removedLines == [1, 2, 3])
        #expect(alignment.addedLines == [1])
        #expect(alignment.newGaps == [2: 2])
        #expect(alignment.oldGaps.isEmpty)
    }

    /// A gap keyed one past the last line has nothing after it to push down.
    /// It is recorded rather than dropped, and ignored when rendering.
    @Test func aChangeAtTheEndIsKeyedPastTheLastLine() {
        let alignment = CompareDiff.align(old: ["a", "b"], new: ["a"])
        #expect(alignment.removedLines == [1])
        #expect(alignment.newGaps == [1: 1])
    }

    @Test func everyLineIsAChangeWhenTheSidesShareNothing() {
        let alignment = CompareDiff.align(old: ["a", "b"], new: ["c", "d"])
        #expect(alignment.removedLines == [0, 1])
        #expect(alignment.addedLines == [0, 1])
        #expect(alignment.oldGaps.isEmpty)
        #expect(alignment.newGaps.isEmpty)
    }

    @Test func anEmptySideIsAllRemovalsOrAllAdditions() {
        let removed = CompareDiff.align(old: ["a", "b"], new: [])
        #expect(removed.removedLines == [0, 1])
        #expect(removed.newGaps == [0: 2])

        let added = CompareDiff.align(old: [], new: ["a", "b"])
        #expect(added.addedLines == [0, 1])
        #expect(added.oldGaps == [0: 2])
    }

    /// Past the ceiling the columns are shown unaligned, and the flag is what
    /// stops an unlevelled view from being read as a wrong diff.
    @Test func anOversizedSideIsReportedAsTruncatedRatherThanAligned() {
        let long = Array(repeating: "a", count: CompareDiff.maxAlignedLines + 1)
        let alignment = CompareDiff.align(old: long, new: ["a"])
        #expect(alignment.isTruncated)
        #expect(!alignment.hasChanges)
        #expect(alignment.oldGaps.isEmpty)
        #expect(alignment.newGaps.isEmpty)

        // Exactly at the ceiling is still aligned.
        let atLimit = Array(repeating: "a", count: CompareDiff.maxAlignedLines)
        #expect(!CompareDiff.align(old: atLimit, new: atLimit).isTruncated)
    }

    /// Every gap in a column has to account for exactly the rows the other
    /// column has that it does not, or the two sides drift apart further down.
    @Test func gapsLevelTheTwoColumnsForAnyPairOfInputs() {
        let cases: [(old: [String], new: [String])] = [
            (["a", "b", "c", "d"], ["b", "c", "e"]),
            (["one", "two"], ["two", "one"]),
            ([], []),
            (["x"], ["x", "x", "x"]),
            (["a", "b", "a", "b"], ["b", "a", "b", "a"]),
        ]
        for (old, new) in cases {
            let alignment = CompareDiff.align(old: old, new: new)
            let oldRows = old.count + alignment.oldGaps.values.reduce(0, +)
            let newRows = new.count + alignment.newGaps.values.reduce(0, +)
            #expect(oldRows == newRows, "\(old) vs \(new)")
        }
    }
}
