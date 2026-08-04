//
//  GitFileContent.swift
//  TerminalCore
//

import Foundation

/// Reads the bytes a diff needs — out of a Git object or off the working tree —
/// under the rules a diff view depends on: a size ceiling, no embedded NULs,
/// valid UTF-8.
///
/// The git-panel diff tabs and the compare view both go through here so the two
/// surfaces apply the same limits and the same untrusted-repository discipline,
/// and so a file that one refuses to render can never be silently rendered as
/// empty text by the other. A repository on the host a terminal has ssh'd into
/// is read under exactly the same rules, over the same connection the file tree
/// already uses.
public nonisolated enum GitFileContent {
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
    static public func firstBlob(
        _ specs: [String], in root: GitDirectory, error: inout String?
    ) -> String {
        for spec in specs {
            switch blob(spec, in: root) {
            case .missing:
                continue
            case .content(let content):
                return content
            case .binary:
                error = String(localized: "Binary file", bundle: .module)
                return ""
            case .tooLarge:
                error = String(localized: "File is too large to diff", bundle: .module)
                return ""
            }
        }
        return ""
    }

    static func blob(_ spec: String, in root: GitDirectory) -> Blob {
        let size = GitCommand.run(["cat-file", "-s", spec], in: root)
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        // Original bytes rather than decoded text, so invalid UTF-8 and an
        // embedded NUL cannot be mistaken for an empty text file. The ceiling
        // is applied again to what came back: the index can change between the
        // size check above and this read while an agent is working.
        let run = GitCommand.runData(["cat-file", "blob", spec], in: root, maxBytes: maxBytes)
        guard run.status == 0 else { return .missing }
        return decoded(run.stdout)
    }

    /// A working-tree file, as a diff's editable side.
    ///
    /// A file that is not there yields an empty side — that is what a deletion
    /// looks like in a diff — while a file that is there but unreadable is
    /// reported instead, because an empty side is itself a claim about the
    /// content.
    static public func worktreeFile(
        root: GitDirectory, path: String, error: inout String?
    ) -> String {
        guard let remote = root.remote else {
            return localFile(at: root.appending(path), error: &error)
        }
        let result = RemoteFileService.execute(
            script: remoteReadScript,
            arguments: [root.appending(path), String(maxBytes + 1)],
            // One more than the ceiling, because the first byte back is the
            // record type rather than content. Without it a file one byte over
            // the ceiling would arrive trimmed to exactly the ceiling and be
            // rendered as though it were whole.
            maxBytes: maxBytes + 1,
            on: remote
        )
        switch result.status {
        case 0:
            break
        case absentStatus:
            return ""
        default:
            error = String(
                localized: "Unable to read file: \(RemoteFileService.sanitized(result.stderr, maxLines: 3))", bundle: .module,
                comment: "Diff error followed by the remote host's own description."
            )
            return ""
        }
        // The leading byte says which branch of the script ran, so a symlink
        // reported as its own target is never confused with a file whose
        // contents happen to start the same way.
        guard let kind = result.stdout.first else { return "" }
        let body = Data(result.stdout.dropFirst())
        guard kind != UInt8(ascii: "l") else {
            // `readlink` ends its answer with a newline that is not part of the
            // link, so it comes off to match what the local read hands back.
            var target = String(decoding: body, as: UTF8.self)
            if target.hasSuffix("\n") { target.removeLast() }
            guard target.utf8.count <= maxBytes else {
                error = String(localized: "File is too large to diff", bundle: .module)
                return ""
            }
            return target
        }
        switch decoded(body) {
        case .content(let text):
            return text
        case .binary:
            error = String(localized: "Binary file", bundle: .module)
        case .tooLarge:
            error = String(localized: "File is too large to diff", bundle: .module)
        case .missing:
            break
        }
        return ""
    }

    /// Reports a symlink as `l` followed by its target, an ordinary file as `f`
    /// followed by its first `$2` bytes, and a path that is not there as
    /// ``absentStatus``.
    ///
    /// The symlink is tested first because `-e` follows links, so a broken one
    /// would otherwise read as absent. `head`'s own status is the script's, so
    /// a file that exists but cannot be read fails rather than coming back
    /// empty.
    private static let remoteReadScript = """
        if [ -L "$1" ]; then printf l; readlink -- "$1"; exit; fi; \
        { [ -e "$1" ] || exit 9; }; \
        printf f; head -c "$2" < "$1"
        """

    /// The script's exit status for a path that is not there. Distinct from
    /// ssh's own 255 and from a shell's 126/127.
    private static let absentStatus: Int32 = 9

    /// Bytes as a diff can show them, or why it cannot.
    private static func decoded(_ data: Data) -> Blob {
        guard data.count <= maxBytes else { return .tooLarge }
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            return .binary
        }
        return .content(content)
    }

    private static func localFile(at path: String, error: inout String?) -> String {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            guard destination.utf8.count <= maxBytes else {
                error = String(localized: "File is too large to diff", bundle: .module)
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
                error = String(localized: "File is too large to diff", bundle: .module)
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
                error = String(localized: "File is too large to diff", bundle: .module)
                return ""
            }
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                error = String(localized: "Binary file", bundle: .module)
                return ""
            }
            return text
        } catch let readError as CocoaError
            where readError.code == .fileNoSuchFile || readError.code == .fileReadNoSuchFile {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        } catch let fileError {
            error = String(
                localized: "Unable to read file: \(fileError.localizedDescription)", bundle: .module,
                comment: "Diff error followed by a system-provided error description."
            )
            return ""
        }
    }
}
