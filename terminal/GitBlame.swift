//
//  GitBlame.swift
//  terminal
//

import Foundation

/// Who last touched one line, and in which commit.
nonisolated struct BlameLine: Equatable, Sendable {
    let oid: String
    let author: String
    let summary: String
    /// Author time as the commit itself recorded it, along with the offset it
    /// was written in. Kept apart from a `Date` so the annotation can show the
    /// commit's own wall clock rather than the reader's.
    let authorTime: TimeInterval
    let authorTimeZone: String

    var shortOID: String { String(oid.prefix(8)) }

    /// Git's sentinel OID for a line that is in no commit yet.
    var isUncommitted: Bool {
        !oid.isEmpty && oid.allSatisfy { $0 == "0" }
    }

    /// `YYYY-MM-DD` in the commit's own timezone. Shifting the epoch by the
    /// recorded offset and reading UTC fields keeps this stable wherever the
    /// reader happens to be.
    var shortDate: String {
        guard authorTime > 0 else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let shifted = Date(timeIntervalSince1970: authorTime + Double(offsetSeconds))
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// `YYYY-MM-DD HH:MM ±ZZZZ`, for the hover.
    var fullDate: String {
        guard authorTime > 0 else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let shifted = Date(timeIntervalSince1970: authorTime + Double(offsetSeconds))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: shifted
        )
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return "" }
        let stamp = String(
            format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute
        )
        return authorTimeZone.isEmpty ? stamp : "\(stamp) \(authorTimeZone)"
    }

    private var offsetSeconds: Int {
        // `+0800` / `-0530`.
        let value = authorTimeZone
        guard value.count == 5, let sign = value.first,
              sign == "+" || sign == "-",
              let hours = Int(value.dropFirst().prefix(2)),
              let minutes = Int(value.suffix(2))
        else { return 0 }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// The end-of-line annotation: `Author, YYYY-MM-DD • summary`.
    var inlineAnnotation: String {
        guard !isUncommitted else {
            return String(
                localized: "Not committed yet",
                comment: "Blame annotation for a line that is not in any commit."
            )
        }
        let date = shortDate
        let head = date.isEmpty ? author : "\(author), \(date)"
        let subject = summary.count > 50
            ? summary.prefix(49) + "…"
            : Substring(summary)
        return subject.isEmpty ? head : "\(head) • \(subject)"
    }
}

/// Reads per-line blame.
///
/// The editable side of a comparison is blamed against the buffer's *current*
/// contents rather than the file on disk, so the annotation keeps naming the
/// right commit while the user types — and a line they just wrote reads as
/// uncommitted instead of borrowing its neighbour's history.
nonisolated enum GitBlame {
    /// `revision` blames the file as of a commit instead of the working tree —
    /// what the read-only column of a comparison is showing. It is mutually
    /// exclusive with `contents`, which Git rejects alongside a revision.
    static func line(
        _ line: Int, path: String, contents: String?,
        revision: String? = nil, in root: String
    ) -> BlameLine? {
        guard line >= 1 else { return nil }
        // A ref must never reach Git as an option; see
        // `GitCompareModel.isSafeRef`.
        if let revision, !GitCompareModel.isSafeRef(revision) { return nil }
        // `core.quotePath=false` emits the porcelain `filename` verbatim as
        // UTF-8 rather than C-quoting anything non-ASCII.
        var args = ["-c", "core.quotePath=false", "blame", "--line-porcelain"]
        let contents = revision == nil ? contents : nil
        if contents != nil { args += ["--contents", "-"] }
        if let revision { args.append(revision) }
        args += ["-L", "\(line),\(line)", "--", path]

        let run = runBlame(args, in: root, input: contents)
        guard run.status == 0 else { return nil }
        return parsePorcelain(run.stdout)
    }

    static func parsePorcelain(_ text: String) -> BlameLine? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first,
              let oid = header.split(separator: " ").first,
              !oid.isEmpty
        else { return nil }

        var author = ""
        var summary = ""
        var authorTime: TimeInterval = 0
        var authorTimeZone = ""
        for line in lines {
            // `author ` is tested before the `author-*` keys. The two never
            // collide — `author-time` has a `-` where `author ` has a space —
            // but each key stays its own branch rather than nesting under a
            // shared prefix.
            if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                authorTime = TimeInterval(
                    line.dropFirst("author-time ".count)
                        .trimmingCharacters(in: .whitespaces)
                ) ?? 0
            } else if line.hasPrefix("author-tz ") {
                authorTimeZone = line.dropFirst("author-tz ".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            }
        }
        return BlameLine(
            oid: String(oid),
            author: author.isEmpty
                ? String(localized: "Unknown author") : author,
            summary: summary,
            authorTime: authorTime,
            authorTimeZone: authorTimeZone
        )
    }

    /// Runs blame with the buffer optionally piped in. Separate from
    /// `GitStatusModel.runGit` only because that one closes stdin outright.
    private static func runBlame(
        _ args: [String], in root: String, input: String?
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Blame is an inspection, so it must never run code the repository
        // supplies; see `GitStatusModel.untrustedConfig`.
        process.arguments = [
            "-c", "core.fsmonitor=",
            "-c", "core.hooksPath=/dev/null",
        ] + args
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        do {
            try process.run()
        } catch {
            return (-1, "")
        }

        if let input {
            // Write on another queue: a buffer larger than the pipe blocks
            // until Git drains it, and Git will not drain while we are not
            // reading its output.
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
