//
//  TerminalHistoryText.swift
//  TerminalCore
//

import Foundation

/// Turns a backend's screen or scrollback dump into something safe to replay
/// into a fresh terminal, or to draw as a thumbnail.
///
/// This is untrusted input twice over: the dump is whatever the shell and the
/// programs it ran printed, and a saved capture is replayed into a live
/// terminal on the next launch. So the parsing lives here, where a hostile
/// sequence can be handed to it directly instead of having to be produced by a
/// real shell first.
public enum TerminalHistoryText {
    public static let reset = "\u{1b}[0m"

    /// Normalizes a backend-emitted VT stream for replay into a fresh terminal,
    /// keeping at most the last `maxLines` rows.
    ///
    /// `isDivider` recognizes a previously replayed restored-history divider so
    /// it is not replayed again; the app supplies it, because which strings
    /// count depends on the language the capture was written under.
    public static func normalized(
        from capture: String, maxLines: Int, isDivider: (String) -> Bool
    ) -> String? {
        guard maxLines > 0 else { return nil }
        let capture = strippingColorConfigurationOSC(from: capture)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = capture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isDivider($0) }

        // Screen dumps include unused rows below the last prompt. ANSI-only
        // rows (for example a trailing SGR reset) are blank for this purpose.
        while let last = lines.last, isVisiblyBlank(last) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }

        let history = lines.joined(separator: "\r\n")
        guard containsANSI(in: history) else { return history }

        // A capped capture may begin in the middle of an attribute run, and a
        // backend dump must never leak its final SGR state into the live prompt.
        var wrapped = history
        if !startsWithReset(wrapped) { wrapped = reset + wrapped }
        if !endsWithReset(wrapped) { wrapped += reset }
        return wrapped
    }

    /// Plain visible rows for the Ctrl-Tab thumbnail, cropped to a box.
    ///
    /// `startedMidStream` says the caller read only the tail of a large dump,
    /// so the first row is a fragment of a line whose beginning — possibly
    /// including half of a UTF-8 scalar or an ANSI run — was never read. It is
    /// dropped rather than shown.
    public static func preview(
        from capture: String, maxLines: Int, maxColumns: Int,
        startedMidStream: Bool
    ) -> String? {
        guard maxLines > 0, maxColumns > 0 else { return nil }
        var capture = capture
        if startedMidStream, let newline = capture.firstIndex(of: "\n") {
            capture.removeSubrange(...newline)
        }
        capture = capture
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = capture
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { visibleText(in: String($0)) }

        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        return lines.suffix(maxLines).map { line in
            var cropped = String(line.prefix(maxColumns))
            while cropped.last == " " || cropped.last == "\t" {
                cropped.removeLast()
            }
            return cropped
        }
        .joined(separator: "\n")
    }

    /// Drops non-printing OSC and CSI sequences for comparisons only. The
    /// original line, including SGR and hyperlinks, is retained in the capture.
    public static func visibleText(in input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            if let sequence = oscSequence(in: scalars, at: index) {
                index = sequence.end
                continue
            }
            if let end = csiSequenceEnd(in: scalars, at: index) {
                index = end
                continue
            }

            let value = scalars[index].value
            if value >= 0x20 && value != 0x7f {
                output.unicodeScalars.append(scalars[index])
            }
            index += 1
        }
        return output
    }

    /// Removes only palette/default-color OSC commands. SGR and semantic OSC
    /// sequences such as hyperlinks remain byte-for-byte intact.
    public static func strippingColorConfigurationOSC(from input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            guard let sequence = oscSequence(in: scalars, at: index) else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            if !isColorConfigurationCommand(in: scalars[sequence.payload]) {
                output.unicodeScalars.append(contentsOf: scalars[index..<sequence.end])
            }
            index = sequence.end
        }
        return output
    }

    public static func isVisiblyBlank(_ line: String) -> Bool {
        visibleText(in: line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isColorConfigurationCommand(
        in payload: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        var command = 0
        var digitCount = 0
        var index = payload.startIndex
        while index < payload.endIndex {
            let value = payload[index].value
            guard (48...57).contains(value) else { break }
            digitCount += 1
            // Every color command of interest is at most three digits. Bail
            // out before arithmetic on an attacker-controlled OSC can overflow.
            guard digitCount <= 3 else { return false }
            command = command * 10 + Int(value - 48)
            index += 1
        }

        guard digitCount > 0,
              index == payload.endIndex || payload[index].value == 59
        else { return false }

        switch command {
        case 4, 5, 10...19, 104, 105, 110...119:
            return true
        default:
            return false
        }
    }

    /// Finds a complete OSC introduced by either ESC ] or the C1 OSC scalar.
    /// BEL, ESC \\, and the C1 ST scalar are all accepted terminators.
    private static func oscSequence(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> (payload: Range<Int>, end: Int)? {
        let payloadStart: Int
        if scalars[index].value == 0x9d {
            payloadStart = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5d {
            payloadStart = index + 2
        } else {
            return nil
        }

        var cursor = payloadStart
        while cursor < scalars.count {
            switch scalars[cursor].value {
            case 0x07, 0x9c:
                return (payloadStart..<cursor, cursor + 1)
            case 0x1b where cursor + 1 < scalars.count
                && scalars[cursor + 1].value == 0x5c:
                return (payloadStart..<cursor, cursor + 2)
            default:
                cursor += 1
            }
        }
        return nil
    }

    private static func csiSequenceEnd(
        in scalars: [Unicode.Scalar], at index: Int
    ) -> Int? {
        let parameterStart: Int
        if scalars[index].value == 0x9b {
            parameterStart = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5b {
            parameterStart = index + 2
        } else {
            return nil
        }

        var cursor = parameterStart
        while cursor < scalars.count {
            if (0x40...0x7e).contains(scalars[cursor].value) {
                return cursor + 1
            }
            cursor += 1
        }
        return nil
    }

    private static func containsANSI(in string: String) -> Bool {
        string.unicodeScalars.contains {
            $0.value == 0x1b || (0x80...0x9f).contains($0.value)
        }
    }

    private static func startsWithReset(_ string: String) -> Bool {
        string.hasPrefix(reset) || string.hasPrefix("\u{1b}[m")
            || string.hasPrefix("\u{9b}0m") || string.hasPrefix("\u{9b}m")
    }

    private static func endsWithReset(_ string: String) -> Bool {
        string.hasSuffix(reset) || string.hasSuffix("\u{1b}[m")
            || string.hasSuffix("\u{9b}0m") || string.hasSuffix("\u{9b}m")
    }
}

/// A backend's screen dump, held to the bargain the backends make: a regular
/// file, alone in a fresh subdirectory of the process temporary directory, with
/// no symlink anywhere on the path.
///
/// The path arrives from the backend as text, and Terminal both reads that file
/// and deletes its directory afterwards — so a path that does not meet the
/// bargain is refused unread rather than trusted because it came from inside.
public struct TerminalCaptureFile {
    public let fileURL: URL
    public let parentURL: URL

    /// Returns the capture only if `emittedPath` names one. Anything else —
    /// a relative path, a symlink, a file directly in the temp directory, a
    /// path somewhere else entirely — is refused.
    public static func validated(for emittedPath: String?) -> TerminalCaptureFile? {
        guard let emittedPath else { return nil }
        let path = emittedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }

        let manager = FileManager.default
        let unresolvedFile = URL(fileURLWithPath: path).standardizedFileURL
        let unresolvedParent = unresolvedFile.deletingLastPathComponent()
        guard let fileValues = try? unresolvedFile.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              fileValues.isRegularFile == true,
              fileValues.isSymbolicLink != true,
              let parentValues = try? unresolvedParent.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true
        else { return nil }

        let fileURL = unresolvedFile.resolvingSymlinksInPath()
        let parentURL = fileURL.deletingLastPathComponent()
        let temporaryDirectory = manager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard parentURL.deletingLastPathComponent() == temporaryDirectory else {
            return nil
        }
        return TerminalCaptureFile(fileURL: fileURL, parentURL: parentURL)
    }

    /// Deletes the capture and the directory it was alone in.
    public func remove() {
        let manager = FileManager.default
        guard (try? manager.removeItem(at: fileURL)) != nil else { return }

        // `rmdir` is deliberately non-recursive: if anything else appeared in
        // the supposedly unique directory, leave it untouched.
        parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = rmdir(path)
        }
    }
}
