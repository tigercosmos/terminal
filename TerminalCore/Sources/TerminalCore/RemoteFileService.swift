//
//  RemoteFileService.swift
//  TerminalCore
//

import Foundation

/// Lists directories and reads files on the far side of an ssh connection, so
/// the Files panel can show the machine the terminal is actually working on.
///
/// Every request is its own `ssh` invocation, but they are not separate
/// logins: the first one opens a multiplexed master that the rest ride on, so
/// expanding a folder costs a round trip rather than a handshake and an
/// authentication. `BatchMode=yes` is what makes this safe to do behind a
/// panel — a host that would ask for a password fails immediately instead of
/// leaving Terminal holding an invisible prompt, and the panel says so.
///
/// Nothing here is stateful: a destination's socket path is derived from the
/// destination itself, so a master left running by an earlier launch is picked
/// up again rather than replaced.
public enum RemoteFileService {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool

        public nonisolated init(name: String, isDirectory: Bool) {
            self.name = name
            self.isDirectory = isDirectory
        }
    }

    /// A directory's contents together with the absolute path the host
    /// resolved it to. The path is what lets a caller ask for a directory it
    /// cannot yet name — `.` right after connecting — and learn where it
    /// landed from the same answer that carries the rows.
    public struct Listing: Equatable, Sendable {
        public let directory: String
        public let entries: [Entry]
    }

    public enum Failure: Error, Equatable, Sendable {
        /// ssh could not reach the host, or would have had to ask the user
        /// something to get there. The panel shows this in place of the tree.
        case unreachable(String)
        /// The connection worked but the path did not: gone, unreadable, or
        /// not the kind of thing that was asked for.
        case pathUnavailable(String)
    }

    /// Runs one of these calls off the main actor and hands back something
    /// that can cross back: a bare `Error` cannot, so anything unexpected is
    /// folded into ``Failure`` rather than escaping as an existential.
    public nonisolated static func attempt<Value: Sendable>(
        _ work: () throws -> Value
    ) -> Result<Value, Failure> {
        do {
            return .success(try work())
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Everything in `directory`, excluding `.` and `..`, along with the path
    /// the host resolved `directory` to.
    ///
    /// A symlink is reported as whatever it points at, so a link to a folder
    /// expands like the folder it is — which is what `ls -p` would not do.
    public nonisolated static func entries(
        in directory: String, on destination: RemoteShellDestination
    ) throws -> Listing {
        let output = try run(script: listScript, arguments: [directory], on: destination)
        // Records are NUL-terminated because a newline is a legal character in
        // a file name, and a separator that can appear in the data is not a
        // separator. The leading byte is the record type.
        var resolved: String?
        var entries: [Entry] = []
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            let value = String(decoding: record.dropFirst(), as: UTF8.self)
            guard !value.isEmpty else { continue }
            switch record.first {
            case UInt8(ascii: "p"): resolved = value
            case UInt8(ascii: "d") where isName(value):
                entries.append(Entry(name: value, isDirectory: true))
            case UInt8(ascii: "f") where isName(value):
                entries.append(Entry(name: value, isDirectory: false))
            default: continue
            }
        }
        guard let resolved, resolved.hasPrefix("/") else {
            throw Failure.pathUnavailable(
                String(localized: "The remote shell did not report a directory.",
                       bundle: .module)
            )
        }
        return Listing(directory: resolved, entries: entries)
    }

    /// Whether `value` is a single directory entry rather than something that
    /// would change which directory a path points at.
    ///
    /// The listing script cannot produce a name containing `/` — a glob never
    /// matches one — but the script is only what Terminal *asked* for. What
    /// comes back is whatever the far end chose to send, and a host that
    /// answered with `../../..` would have the panel build a path that walks
    /// out of the tree and lands somewhere on this machine, which is then what
    /// a drag or a Copy Path would hand over.
    private nonisolated static func isName(_ value: String) -> Bool {
        !value.contains("/") && value != "." && value != ".."
    }

    /// The first `maxBytes` of `path`, and whether the file went past them.
    /// The ceiling is the caller's, so a file that opens locally opens here.
    public nonisolated static func contents(
        of path: String, on destination: RemoteShellDestination, maxBytes: Int
    ) throws -> (data: Data, isTruncated: Bool) {
        // The redirect rather than an argument keeps a name that begins with
        // `-` from being read as an option, and makes a directory fail here
        // instead of producing nonsense.
        //
        // One byte past the ceiling, so a file sitting exactly on it can be
        // told from one that runs over. Asking for the ceiling itself makes
        // them identical, and a file the local reader opens happily would be
        // refused for being too large the moment it came over a connection.
        let data = try run(
            script: "head -c \(maxBytes + 1) < \"$1\"", arguments: [path], on: destination
        )
        return (data, data.count > maxBytes)
    }

    /// Closes the multiplexed master, if Terminal opened one. Called when the
    /// panels stop following a destination, so a connection does not outlive
    /// the reason it existed by the whole `ControlPersist` window.
    public nonisolated static func disconnect(from destination: RemoteShellDestination) {
        guard let controlPath = controlPath(for: destination) else { return }
        _ = runSSH(
            arguments: ["-o", "ControlPath=\(controlPath)", "-O", "exit", destination.destination]
        )
    }

    // MARK: - Remote commands

    /// Lists a directory as NUL-terminated `<type><name>` records, preceded by
    /// a `p` record naming the directory the host resolved.
    ///
    /// `for` over both globs rather than `ls` because `ls` decides for itself
    /// how to quote unusual names, and because `[ -d ]` follows symlinks while
    /// `ls -p` does not. The unmatched-glob case is caught by the existence
    /// test: a shell with no matches passes the pattern through literally.
    private nonisolated static let listScript = """
        cd -- "$1" 2>/dev/null || exit 3; \
        printf "p%s\\0" "$(pwd)"; \
        for entry in .* *; do \
        [ "$entry" = . ] && continue; \
        [ "$entry" = .. ] && continue; \
        { [ -e "$entry" ] || [ -L "$entry" ]; } || continue; \
        if [ -d "$entry" ]; then printf "d%s\\0" "$entry"; \
        else printf "f%s\\0" "$entry"; fi; \
        done; exit 0
        """

    /// Runs `script` on the remote host with `arguments` as `$1`, `$2`, … and
    /// hands back exactly what it said.
    ///
    /// Separate from ``run(script:arguments:on:)`` because a Git command's own
    /// exit status is information the panels display — a revision that is not
    /// in the repository is not a connection problem — so the caller needs the
    /// status and the diagnostics apart rather than folded into a ``Failure``.
    ///
    /// `maxBytes`, when set, caps how much of stdout is retained; the pipe is
    /// drained past it either way, because a remote command nobody reads
    /// eventually blocks. `input` is fed to the command's stdin.
    public nonisolated static func execute(
        script: String, arguments: [String], maxBytes: Int? = nil,
        input: Data? = nil, on destination: RemoteShellDestination
    ) -> (status: Int32, stdout: Data, stderr: String) {
        runSSH(
            arguments: sshInvocation(script: script, arguments: arguments, on: destination),
            maxBytes: maxBytes,
            input: input
        )
    }

    /// The full `ssh` argument vector that runs `script` on `destination`.
    ///
    /// The command reaches the remote login shell as one string, so it is
    /// assembled with the paths single-quoted; the scripts themselves contain
    /// no single quote for that reason. Passing the paths as arguments rather
    /// than interpolating them into the script keeps a file name from being
    /// read as shell syntax twice over.
    ///
    /// `/bin/sh` rather than the command on its own because the remote login
    /// shell may be csh or fish, where a leading `NAME=value` is not an
    /// assignment at all — the scripts that need an environment set it inside
    /// the `sh` they are already running in.
    private nonisolated static func sshInvocation(
        script: String, arguments: [String], on destination: RemoteShellDestination
    ) -> [String] {
        let remoteCommand = (["/bin/sh", "-c", script, "sh"] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")
        var sshArguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        // A user who set up their own control socket already has a master
        // running; ride on it rather than opening a second one beside it.
        if let controlPath = controlPath(for: destination),
           !destination.reachOptions.contains("-S") {
            sshArguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=90",
            ]
        }
        // `-T` sits after the user's own options so it wins over a `-o
        // RequestTTY` of theirs; the `-o` options above sit before them
        // because ssh keeps the first value it is given for a setting.
        sshArguments += destination.reachOptions
        sshArguments += ["-T", destination.destination, remoteCommand]
        return sshArguments
    }

    /// Runs `script` and folds anything other than success into a ``Failure``,
    /// which is what the file listings want: they have nothing to say about a
    /// non-zero status beyond "that path could not be read".
    private nonisolated static func run(
        script: String, arguments: [String], on destination: RemoteShellDestination
    ) throws -> Data {
        let result = execute(script: script, arguments: arguments, on: destination)
        switch result.status {
        case 0:
            return result.stdout
        // ssh reports its own failures — connection refused, host key
        // mismatch, an authentication that would have needed the user — as
        // 255, and anything else as the remote command's own status.
        case 255, -1:
            throw Failure.unreachable(
                message(from: result.stderr)
                    ?? String(localized: "Terminal couldn’t connect to this host.",
                              bundle: .module)
            )
        default:
            throw Failure.pathUnavailable(
                message(from: result.stderr)
                    ?? String(localized: "That path couldn’t be read on the remote host.",
                              bundle: .module)
            )
        }
    }

    private nonisolated static func runSSH(
        arguments: [String], maxBytes: Int? = nil, input: Data? = nil
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Neither prompt can be answered from behind a panel. `BatchMode`
        // covers ssh's own prompts; these cover the helpers it may reach for.
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["DISPLAY"] = nil
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
        if let input {
            // Written on another queue: a buffer larger than the pipe blocks
            // until ssh drains it, and ssh will not drain it while nothing is
            // reading what it sends back.
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        // Draining both pipes concurrently: waiting on the process first
        // deadlocks as soon as either fills, and a directory listing can.
        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        // Read at the caller's priority: it blocks on these below, so pinning
        // them to utility inverts the priority of a user-initiated listing.
        let readerQoS = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .utility
        readers.enter()
        DispatchQueue.global(qos: readerQoS).async {
            outData.value = read(stdout.fileHandleForReading, retaining: maxBytes)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: readerQoS).async {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            outData.value,
            String(decoding: errData.value, as: UTF8.self)
        )
    }

    /// Drains `handle`, keeping at most `limit` bytes plus one — enough to tell
    /// a payload that sits exactly on a caller's ceiling from one that runs
    /// over it. Everything past that is read and dropped, because a remote
    /// command whose output nobody takes eventually blocks.
    private nonisolated static func read(
        _ handle: FileHandle, retaining limit: Int?
    ) -> Data {
        guard let limit else { return handle.readDataToEndOfFile() }
        var kept = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            let remaining = limit + 1 - kept.count
            if remaining > 0 { kept.append(chunk.prefix(remaining)) }
        }
        return kept
    }

    private nonisolated final class PipeData: @unchecked Sendable {
        var value = Data()
    }

    /// The socket Terminal multiplexes a destination's connections through.
    ///
    /// Nil when the path would be too long for a Unix socket, in which case
    /// each request pays for its own connection — slower, but every
    /// alternative shortening involves a directory other users can write to,
    /// and an attacker-placed socket is an ssh connection under their control.
    private nonisolated static func controlPath(for destination: RemoteShellDestination) -> String? {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let identity = ([destination.destination] + destination.reachOptions).joined(separator: "\u{0}")
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(String(format: "terminal-ssh-%016llx", hash))
        // `sun_path` is 104 bytes on Darwin, and ssh appends nothing to a
        // literal `ControlPath`.
        return path.utf8.count < 104 ? path : nil
    }

    /// The most specific line of ssh's diagnostics, made safe to show.
    private nonisolated static func message(from stderr: String) -> String? {
        guard let last = visibleLines(of: stderr).last else { return nil }
        return last.count > 200 ? String(last.prefix(200)) + "…" : last
    }

    /// Remote-influenced text made safe to show, keeping its shape.
    ///
    /// Anything a remote command writes is on its way into the interface, so
    /// control characters come out and both the line count and each line's
    /// length are capped; a banner, a motd, or a hostile diagnostic should not
    /// be able to redraw the panel or run it out of memory.
    public nonisolated static func sanitized(_ text: String, maxLines: Int = 20) -> String {
        let lines = visibleLines(of: text)
        let kept = lines.prefix(maxLines).map { line in
            line.count > 500 ? String(line.prefix(500)) + "…" : line
        }
        let elided = lines.count - kept.count
        return elided > 0
            ? (kept + [String(localized: "…and \(elided) more lines", bundle: .module)])
                .joined(separator: "\n")
            : kept.joined(separator: "\n")
    }

    /// `text` split into non-empty lines with every non-printing scalar taken
    /// out. Line separators are what the split consumed, so nothing here can
    /// reintroduce one.
    private nonisolated static func visibleLines(of text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                let visible = line.unicodeScalars.filter { scalar in
                    switch scalar.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator: false
                    default: true
                    }
                }
                return String(String.UnicodeScalarView(visible))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
