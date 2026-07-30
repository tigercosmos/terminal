//
//  GitFileContent.swift
//  terminal
//

import Foundation

/// Mutable pipe storage shared by the two background readers in
/// `GitFileContent.runGitData`. Each instance is written by exactly one reader.
private nonisolated final class GitPipeData: @unchecked Sendable {
    var value = Data()
}

/// Reads the bytes a diff needs — out of a Git object or off the working tree —
/// under the rules a diff view depends on: a size ceiling, no embedded NULs,
/// valid UTF-8.
///
/// The git-panel diff tabs and the compare view both go through here so the two
/// surfaces apply the same limits and the same untrusted-repository discipline,
/// and so a file that one refuses to render can never be silently rendered as
/// empty text by the other.
nonisolated enum GitFileContent {
    /// Ceiling for either side of a diff. Past this the caller reports the file
    /// as too large instead of loading it.
    static let maxBytes = 5 << 20

    enum Blob {
        case missing
        case content(String)
        case binary
        case tooLarge
    }

    /// Content of the first spec that exists, so a caller can express a
    /// preference order (our side of a conflict, then the merge base, …).
    /// Reports binary/too-large through `error` and yields an empty side.
    static func firstBlob(
        _ specs: [String], in root: String, error: inout String?
    ) -> String {
        for spec in specs {
            switch blob(spec, in: root) {
            case .missing:
                continue
            case .content(let content):
                return content
            case .binary:
                error = String(localized: "Binary file")
                return ""
            case .tooLarge:
                error = String(localized: "File is too large to diff")
                return ""
            }
        }
        return ""
    }

    static func blob(_ spec: String, in root: String) -> Blob {
        let size = GitStatusModel.runGit(["cat-file", "-s", spec], in: root)
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        let run = runGitData(["cat-file", "blob", spec], in: root)
        guard run.status == 0 else { return .missing }
        guard run.stdout.count <= maxBytes else { return .tooLarge }
        guard !run.stdout.contains(0),
              let content = String(data: run.stdout, encoding: .utf8)
        else {
            return .binary
        }
        return .content(content)
    }

    /// GitStatusModel's general runner intentionally exposes decoded text.
    /// Diff blobs need their original bytes so invalid UTF-8 and embedded NULs
    /// cannot be mistaken for an empty text file.
    static func runGitData(
        _ args: [String], in root: String
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Reading a blob must never run code the repository supplies; see
        // `GitStatusModel.untrustedConfig`.
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
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }

        let outData = GitPipeData()
        let errData = GitPipeData()
        let captureLimit = maxBytes + 1
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            // Drain the pipe so Git cannot deadlock, but retain at most one
            // byte beyond the limit. The index may change between cat-file's
            // size check and this read while an agent is working.
            while true {
                let chunk: Data
                do {
                    guard let next = try stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                let remaining = captureLimit - outData.value.count
                if remaining > 0 {
                    outData.value.append(chunk.prefix(remaining))
                }
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            outData.value,
            String(data: errData.value, encoding: .utf8) ?? ""
        )
    }

    static func worktreeFile(
        root: String, path: String, error: inout String?
    ) -> String {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            guard destination.utf8.count <= maxBytes else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            return destination
        }
        do {
            // Keep one descriptor for the whole read: replacing the path while
            // an agent writes cannot redirect us to a different, larger file.
            // Seek checks catch growth without ever loading more than maxBytes.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            try handle.seek(toOffset: 0)

            var data = Data()
            while data.count < maxBytes {
                let remaining = min(64 * 1024, maxBytes - data.count)
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            let finalSize = try handle.seekToEnd()
            guard finalSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                error = String(localized: "Binary file")
                return ""
            }
            return text
        } catch let readError as CocoaError
            where readError.code == .fileNoSuchFile || readError.code == .fileReadNoSuchFile {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        } catch let fileError {
            error = String(
                localized: "Unable to read file: \(fileError.localizedDescription)",
                comment: "Diff error followed by a system-provided error description."
            )
            return ""
        }
    }
}
