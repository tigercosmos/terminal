//
//  TerminalHistoryTextTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

private let esc = "\u{1b}"
private let reset = TerminalHistoryText.reset

/// A capture is whatever the shell and everything it ran printed, and it gets
/// replayed into a live terminal on the next launch. Feeding hostile sequences
/// straight in is the only practical way to check that.
struct TerminalHistoryTextTests {
    private func normalized(_ capture: String, maxLines: Int = 100) -> String? {
        TerminalHistoryText.normalized(
            from: capture, maxLines: maxLines, isDivider: { _ in false }
        )
    }

    // MARK: - Normalizing for replay

    @Test func plainRowsComeBackJoinedWithCRLFAndUntouched() {
        #expect(normalized("one\ntwo") == "one\r\ntwo")
        #expect(normalized("one\r\ntwo") == "one\r\ntwo")
        #expect(normalized("one\rtwo") == "one\r\ntwo")
    }

    /// A screen dump is a full grid, so the unused rows under the last prompt
    /// come with it. Replaying them would push the live prompt off-screen.
    @Test func theBlankRowsUnderTheLastPromptAreDropped() {
        #expect(normalized("hello\n\n   \n") == "hello")
        // An ANSI-only row is blank for this purpose too.
        #expect(normalized("hello\n\(reset)\n") == "hello")
    }

    @Test func aCaptureWithNothingVisibleInItIsNoHistoryAtAll() {
        #expect(normalized("") == nil)
        #expect(normalized("\n\n\n") == nil)
        #expect(normalized("\(reset)") == nil)
        #expect(normalized("hello", maxLines: 0) == nil)
    }

    @Test func onlyTheLastRowsAreKept() {
        #expect(normalized("a\nb\nc\nd", maxLines: 2) == "c\r\nd")
    }

    /// A capped capture can begin mid-attribute-run, and the dump's final SGR
    /// state must never leak into the live prompt underneath it.
    @Test func styledHistoryIsBracketedByResets() {
        let styled = "\(esc)[31mred"
        let result = normalized(styled)
        #expect(result?.hasPrefix(reset) == true)
        #expect(result?.hasSuffix(reset) == true)
        #expect(result?.contains("\(esc)[31mred") == true)
    }

    /// Already-bracketed history is not wrapped again — a second reset would
    /// grow the capture a little on every save-and-restore cycle.
    @Test func alreadyBracketedHistoryIsNotWrappedAgain() {
        let already = "\(reset)red\(reset)"
        #expect(normalized(already) == already)
        // The shorter spellings of a reset count as one too.
        let short = "\(esc)[mred\(esc)[m"
        #expect(normalized(short) == short)
    }

    @Test func historyWithNoEscapesAtAllIsLeftExactlyAsItIs() {
        #expect(normalized("plain")?.contains(esc) == false)
    }

    /// The divider a previous restore wrote is dropped rather than replayed,
    /// or every relaunch would stack another one.
    @Test func rowsTheCallerCallsDividersAreDropped() {
        let result = TerminalHistoryText.normalized(
            from: "one\n--- divider ---\ntwo", maxLines: 100,
            isDivider: { $0.contains("divider") }
        )
        #expect(result == "one\r\ntwo")
    }

    // MARK: - Stripping color configuration

    /// A capture that reset the palette would repaint the *live* terminal when
    /// replayed, overriding the user's theme. Those commands are dropped; the
    /// styling of the text itself is not.
    @Test func paletteAndDefaultColorCommandsAreRemoved() {
        for command in ["4;1;#ff0000", "10;#ffffff", "104", "110", "5;0;#000000"] {
            let capture = "before\(esc)]\(command)\u{07}after"
            #expect(
                TerminalHistoryText.strippingColorConfigurationOSC(from: capture)
                    == "beforeafter",
                "OSC \(command) should have been removed"
            )
        }
    }

    /// Hyperlinks, titles, and anything else semantic survive byte for byte.
    @Test func otherOSCSequencesSurviveByteForByte() {
        let link = "\(esc)]8;;https://example.test\u{07}text\(esc)]8;;\u{07}"
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(from: link) == link)
        let title = "\(esc)]0;a title\u{07}rest"
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(from: title) == title)
    }

    @Test func everyOSCTerminatorIsRecognized() {
        for terminator in ["\u{07}", "\(esc)\\", "\u{9c}"] {
            let capture = "a\(esc)]104\(terminator)b"
            #expect(
                TerminalHistoryText.strippingColorConfigurationOSC(from: capture) == "ab",
                "terminator \(terminator.debugDescription) should have closed the OSC"
            )
        }
        // The C1 introducer works the same as ESC ].
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(
            from: "a\u{9d}104\u{07}b"
        ) == "ab")
    }

    /// An unterminated OSC runs to the end of the capture. It is left in place
    /// rather than swallowing everything after it.
    @Test func anUnterminatedOSCIsLeftAlone() {
        let capture = "a\(esc)]104no terminator here"
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(from: capture) == capture)
    }

    /// A command number long enough to overflow the accumulator is refused
    /// before the arithmetic, not after.
    @Test func anAbsurdlyLongCommandNumberIsNotTreatedAsAColorCommand() {
        let capture = "a\(esc)]000000000000000000004;x\u{07}b"
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(from: capture) == capture)
    }

    /// `104` is a palette reset; `1040` is not. Matching a prefix would drop
    /// sequences that belong to the capture.
    @Test func aLongerNumberIsNotMistakenForAColorCommand() {
        let capture = "a\(esc)]1040\u{07}b"
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(from: capture) == capture)
        // …and a command with no digits at all is not one either.
        #expect(TerminalHistoryText.strippingColorConfigurationOSC(
            from: "a\(esc)];x\u{07}b"
        ) == "a\(esc)];x\u{07}b")
    }

    // MARK: - Visible text

    @Test func visibleTextDropsSequencesAndControlCharacters() {
        #expect(TerminalHistoryText.visibleText(in: "\(esc)[31mred\(reset)") == "red")
        #expect(TerminalHistoryText.visibleText(in: "a\(esc)]0;title\u{07}b") == "ab")
        #expect(TerminalHistoryText.visibleText(in: "a\u{7f}b\u{01}c") == "abc")
        // C1 introducers count as sequences too.
        #expect(TerminalHistoryText.visibleText(in: "a\u{9b}31mb") == "ab")
    }

    @Test func visibleTextKeepsTheTextItself() {
        #expect(TerminalHistoryText.visibleText(in: "plain 文字 🙂") == "plain 文字 🙂")
        #expect(TerminalHistoryText.isVisiblyBlank("\(esc)[31m   \(reset)"))
        #expect(!TerminalHistoryText.isVisiblyBlank("\(esc)[31m x \(reset)"))
    }

    // MARK: - Preview

    private func preview(
        _ capture: String, maxLines: Int = 10, maxColumns: Int = 20,
        startedMidStream: Bool = false
    ) -> String? {
        TerminalHistoryText.preview(
            from: capture, maxLines: maxLines, maxColumns: maxColumns,
            startedMidStream: startedMidStream
        )
    }

    @Test func aPreviewIsPlainTextCroppedToTheBox() {
        #expect(preview("\(esc)[31mred\(reset)\ntwo") == "red\ntwo")
        #expect(preview("abcdef", maxColumns: 3) == "abc")
        #expect(preview("a\nb\nc", maxLines: 2) == "b\nc")
        #expect(preview("a   \nb\t") == "a\nb")
    }

    /// A tail read starts partway through a row whose beginning — possibly half
    /// a UTF-8 scalar or an ANSI run — was never read, so that row is dropped.
    @Test func aTailReadDropsItsFirstPartialRow() {
        #expect(preview("gment\nwhole", startedMidStream: true) == "whole")
        #expect(preview("gment\nwhole", startedMidStream: false) == "gment\nwhole")
        // A tail with no newline anywhere in it is a single row, and there is
        // nothing better to show than the part that was read.
        #expect(preview("fragment", startedMidStream: true) == "fragment")
    }

    @Test func anEmptyOrDegenerateBoxHasNoPreview() {
        #expect(preview("", maxLines: 10) == nil)
        #expect(preview("   \n\n") == nil)
        #expect(preview("text", maxLines: 0) == nil)
        #expect(preview("text", maxColumns: 0) == nil)
    }
}

/// The path to a screen dump arrives as text from the backend, and Terminal
/// both reads that file and then deletes the directory it was in. Every way a
/// path can fail the bargain is checked here, because the failure mode is
/// reading or deleting something that was never a capture.
struct TerminalCaptureFileTests {
    /// A capture as the backends actually produce one: a file alone in a fresh
    /// subdirectory of the process temporary directory.
    private func makeCapture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false
        )
        let file = directory.appendingPathComponent("screen.txt")
        try Data("hello".utf8).write(to: file)
        return (directory, file)
    }

    @Test func aWellFormedCaptureIsAccepted() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = try #require(TerminalCaptureFile.validated(for: file.path))
        #expect(capture.fileURL.lastPathComponent == "screen.txt")
        #expect(capture.parentURL.lastPathComponent == directory.lastPathComponent)
    }

    /// Surrounding whitespace is what an emitted line carries, not a different
    /// path.
    @Test func aPathIsTrimmedBeforeItIsJudged() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(TerminalCaptureFile.validated(for: "  \(file.path)\n") != nil)
    }

    @Test func nothingRelativeOrEmptyOrNULBearingIsAccepted() {
        #expect(TerminalCaptureFile.validated(for: nil) == nil)
        #expect(TerminalCaptureFile.validated(for: "") == nil)
        #expect(TerminalCaptureFile.validated(for: "relative/screen.txt") == nil)
        #expect(TerminalCaptureFile.validated(for: "/tmp/screen\0.txt") == nil)
    }

    @Test func aPathThatIsNotARegularFileIsRefused() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The directory itself, and a file that is not there at all.
        #expect(TerminalCaptureFile.validated(for: directory.path) == nil)
        #expect(TerminalCaptureFile.validated(
            for: directory.appendingPathComponent("absent.txt").path
        ) == nil)
        #expect(TerminalCaptureFile.validated(for: file.path) != nil)
    }

    /// A symlinked capture would let its target be read and its directory
    /// removed, so the link is refused rather than followed.
    @Test func aSymlinkedCaptureIsRefused() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(TerminalCaptureFile.validated(for: link.path) == nil)
    }

    /// The capture has to sit one level down. A file directly in the temp
    /// directory would make that whole directory the one cleanup removes.
    @Test func aCaptureDirectlyInTheTemporaryDirectoryIsRefused() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loose-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(TerminalCaptureFile.validated(for: file.path) == nil)
    }

    /// Two levels down is not the bargain either — the directory removed would
    /// be one the backend never created.
    @Test func aCaptureNestedTooDeeplyIsRefused() throws {
        let (directory, _) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deeper = directory.appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: false)
        let file = deeper.appendingPathComponent("screen.txt")
        try Data("hello".utf8).write(to: file)
        #expect(TerminalCaptureFile.validated(for: file.path) == nil)
    }

    /// Removal takes the file and the directory it was alone in, and nothing
    /// else — a directory that grew a second file is left where it is.
    @Test func removalTakesTheCaptureAndItsDirectoryOnly() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try #require(TerminalCaptureFile.validated(for: file.path))
        capture.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aDirectoryHoldingSomethingElseSurvivesRemoval() throws {
        let (directory, file) = try makeCapture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = directory.appendingPathComponent("something-else.txt")
        try Data("keep".utf8).write(to: other)

        let capture = try #require(TerminalCaptureFile.validated(for: file.path))
        capture.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
