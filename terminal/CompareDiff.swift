//
//  CompareDiff.swift
//  terminal
//

import Foundation

/// Line-level alignment between the two columns of a comparison.
///
/// Neither column is padded with filler text. Both text views hold exactly
/// their real content, so each gutter numbers its own side correctly and the
/// editable column stays byte-for-byte the file on disk — the whole point of
/// comparing while you edit. Rows are levelled with blank space drawn *before*
/// a line instead, which is a styling attribute and never content.
struct CompareAlignment: Equatable {
    /// Blank rows that must appear before a line for the two columns to stay
    /// level, keyed by zero-based line index. A line absent from the map has no
    /// gap. A key one past the last line is a gap at the end of the column,
    /// which has nothing after it to push down and is ignored when rendering.
    var oldGaps: [Int: Int] = [:]
    var newGaps: [Int: Int] = [:]
    /// Zero-based indices of lines that exist only at the target.
    var removedLines: [Int] = []
    /// Zero-based indices of lines that exist only in the working tree.
    var addedLines: [Int] = []
    /// True when the two sides were too large to align and are shown
    /// unaligned. Surfaced in the UI so an unlevelled view is never mistaken
    /// for a wrong diff.
    var isTruncated = false

    var hasChanges: Bool { !removedLines.isEmpty || !addedLines.isEmpty }
}

enum CompareDiff {
    /// Above this many lines on either side, the O(n·d) line diff stops being
    /// worth its latency and the columns are shown unaligned. A file this long
    /// is past the point where reading a side-by-side diff helps anyway.
    static let maxAlignedLines = 20_000

    /// Splits text into the lines a text view lays out, so a line index here is
    /// the same line index the gutter numbers. A trailing newline therefore
    /// yields a final empty line, exactly as the editor renders it.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Byte offset where each line starts, used to map a layout position back
    /// to a line index while drawing.
    static func lineStartOffsets(_ lines: [String]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            // +1 for the newline that separated this line from the next.
            offset += line.utf16.count + 1
        }
        return offsets
    }

    static func align(old: [String], new: [String]) -> CompareAlignment {
        var alignment = CompareAlignment()
        guard old.count <= maxAlignedLines, new.count <= maxAlignedLines else {
            alignment.isTruncated = true
            return alignment
        }

        let difference = new.difference(from: old)
        guard !difference.isEmpty else { return alignment }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }

        // Walk both sides together. Old lines that were not removed pair up, in
        // order, with new lines that were not inserted, so anything else is a
        // change block — a run of removals followed by a run of insertions.
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            let isRemoval = oldIndex < old.count && removed.contains(oldIndex)
            let isInsertion = newIndex < new.count && inserted.contains(newIndex)
            guard isRemoval || isInsertion else {
                oldIndex += 1
                newIndex += 1
                continue
            }

            var removedRun = 0
            while oldIndex < old.count, removed.contains(oldIndex) {
                alignment.removedLines.append(oldIndex)
                oldIndex += 1
                removedRun += 1
            }
            var addedRun = 0
            while newIndex < new.count, inserted.contains(newIndex) {
                alignment.addedLines.append(newIndex)
                newIndex += 1
                addedRun += 1
            }

            // The shorter half of the block gets blank rows before whatever
            // follows it, so the next matching pair lands on the same row.
            if removedRun > addedRun {
                alignment.newGaps[newIndex, default: 0] += removedRun - addedRun
            } else if addedRun > removedRun {
                alignment.oldGaps[oldIndex, default: 0] += addedRun - removedRun
            }
        }
        return alignment
    }
}
