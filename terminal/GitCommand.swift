//
//  GitCommand.swift
//  terminal
//

import Dispatch
import Foundation

/// A directory Git runs in, together with the machine it is on.
///
/// The panels ask Git the same questions whether the repository is on this Mac
/// or on the host a terminal has ssh'd into — only where the command runs
/// differs. Carrying the two together is what keeps a remote path from ever
/// reaching a local `git`, which would answer about whatever happens to sit at
/// that path here.
nonisolated struct GitDirectory: Equatable, Hashable, Sendable {
    /// Absolute path on whichever machine ``remote`` names. Empty while a
    /// panel has not resolved one yet, and `.` for a host that could not say
    /// where its terminal is — an ssh command lands in the login directory,
    /// which is the same place the file tree roots at.
    let path: String

    /// The ssh connection the directory sits behind, or nil for this Mac.
    let remote: RemoteShellDestination?

    init(_ path: String, on remote: RemoteShellDestination? = nil) {
        self.path = path
        self.remote = remote
    }

    var isLocal: Bool { remote == nil }

    /// The host the directory is on, when it is not this machine.
    var host: String? { remote?.host }

    /// Another directory on the same machine.
    func directory(_ path: String) -> GitDirectory {
        GitDirectory(path, on: remote)
    }

    /// A repository-relative path resolved against this directory. Still a
    /// path on ``remote``'s machine, so it is only ever handed back to Git or
    /// to ssh — never to `FileManager`.
    func appending(_ relativePath: String) -> String {
        (path as NSString).appendingPathComponent(relativePath)
    }

    /// The `host:/path` shape scp uses, so a remote path shown in the
    /// interface can never be read as a local one.
    var displayPath: String {
        guard let host else { return path }
        return path == "." || path.isEmpty ? host : "\(host):\(path)"
    }
}

/// Runs Git for the panels, on this Mac or on the host a terminal is ssh'd
/// into.
///
/// Every Git read and every Git action in the app goes through here, so the
/// untrusted-repository discipline below is applied once rather than at each
/// call site, and so a remote repository is inspected under exactly the rules
/// a local one is.
nonisolated enum GitCommand {
    /// Config that neutralizes the two settings a repository can use to make
    /// Git execute a command on Terminal's behalf. `core.fsmonitor` runs on any
    /// index refresh — including the `status` Terminal issues the moment a
    /// project directory is opened — so a downloaded repository, or one an
    /// agent has written `.git/config` in, would otherwise get code execution
    /// with no user action at all. `core.hooksPath` is disabled for the same
    /// reason: `status` can write the index and fire `post-index-change`.
    ///
    /// Hooks are a legitimate part of an *explicit* Git action, so
    /// `allowingRepositoryHooks` re-enables them for the commands the operation
    /// runners execute. `core.fsmonitor` stays off everywhere: it is only a
    /// performance hint, and Terminal never needs it.
    private static let untrustedConfig = ["-c", "core.fsmonitor="]
    private static let noHooksConfig = ["-c", "core.hooksPath=/dev/null"]

    /// The environment every Git invocation runs under. `GIT_TERMINAL_PROMPT`
    /// makes a credential prompt fail rather than hang behind the app, and the
    /// pinned locale is what makes Git's diagnostics safe to match on.
    private static let environment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
    ]

    /// Sets that environment inside the `sh` the remote command already runs
    /// in, then becomes the Git process. The assignments cannot be sent as a
    /// bare command prefix: the remote login shell may be csh or fish, where
    /// `NAME=value command` is not an assignment.
    private static let remoteEnvironmentScript = environment
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ") + " exec \"$@\""

    /// Runs Git and hands back its decoded output.
    static func run(
        _ args: [String], in directory: GitDirectory,
        allowingRepositoryHooks: Bool = false
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = runData(
            args, in: directory, allowingRepositoryHooks: allowingRepositoryHooks
        )
        // Undecodable output is treated as no output rather than repaired: the
        // callers parse NUL-delimited records where a replacement character
        // would silently become part of a path.
        return (
            result.status,
            String(data: result.stdout, encoding: .utf8) ?? "",
            result.stderr
        )
    }

    /// Runs Git and hands back its original bytes.
    ///
    /// Diff blobs need these rather than decoded text, so invalid UTF-8 and
    /// embedded NULs cannot be mistaken for an empty text file. `maxBytes`
    /// caps what is retained, keeping one byte past the ceiling so a payload
    /// sitting exactly on it can be told from one that runs over.
    static func runData(
        _ args: [String], in directory: GitDirectory,
        allowingRepositoryHooks: Bool = false,
        maxBytes: Int? = nil, input: Data? = nil
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let arguments = untrustedConfig
            + (allowingRepositoryHooks ? [] : noHooksConfig)
            + args
        guard let remote = directory.remote else {
            return runLocal(arguments, in: directory.path, maxBytes: maxBytes, input: input)
        }
        // `-C` rather than a remote `cd`: it is Git's own way of naming the
        // directory to work in, and it fails loudly on a path that is gone
        // instead of running the command somewhere else.
        let result = RemoteFileService.execute(
            script: remoteEnvironmentScript,
            arguments: ["git", "-C", directory.path] + arguments,
            maxBytes: maxBytes,
            input: input,
            on: remote
        )
        // Everything the far side wrote is remote-influenced text on its way
        // into the interface — a repository's own hook can write to stderr
        // during a push, and so can a login banner.
        return (result.status, result.stdout, RemoteFileService.sanitized(result.stderr))
    }

    /// Which of `names` exist directly inside `directory`.
    ///
    /// Used to read the markers Git leaves in a repository's own directory for
    /// an interrupted rebase or merge, which no plumbing command reports.
    static func existingNames(_ names: [String], in directory: GitDirectory) -> Set<String> {
        guard let remote = directory.remote else {
            let fm = FileManager.default
            return Set(names.filter { fm.fileExists(atPath: directory.appending($0)) })
        }
        let result = RemoteFileService.execute(
            script: existsScript, arguments: [directory.path] + names, on: remote
        )
        guard result.status == 0 else { return [] }
        // NUL-terminated because the caller compares against names it supplied
        // and nothing else may be read out of the answer.
        let reported = Set(
            result.stdout
                .split(separator: 0, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
        )
        return Set(names.filter(reported.contains))
    }

    /// Reports which of `$2`, `$3`, … exist inside `$1`, NUL-terminated.
    /// `exit 0` because a final test that fails would otherwise be the
    /// script's own status and read as a failed connection.
    private static let existsScript = """
        dir=$1; shift; \
        for name in "$@"; do \
        [ -e "$dir/$name" ] && printf "%s\\0" "$name"; \
        done; exit 0
        """

    // MARK: - Local execution

    /// Runs Git on this machine, draining stdout and stderr concurrently.
    /// Reading either pipe only after the process exits can deadlock when the
    /// other fills, and a status listing can fill one.
    private static func runLocal(
        _ arguments: [String], in path: String, maxBytes: Int?, input: Data?
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { processEnvironment[key] = value }
        process.environment = processEnvironment

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
            // until Git drains it, and Git will not drain it while nothing is
            // reading its output.
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outData.value = read(stdout.fileHandleForReading, retaining: maxBytes)
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

    /// Drains `handle`, keeping at most `limit` bytes plus one. Everything past
    /// that is read and dropped: the index can change between a `cat-file -s`
    /// size check and this read while an agent is working, and a Git process
    /// nobody reads from blocks.
    private static func read(_ handle: FileHandle, retaining limit: Int?) -> Data {
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

    private final class PipeData: @unchecked Sendable {
        var value = Data()
    }
}

/// Where a terminal is on the host it has ssh'd into, once the host has been
/// asked.
///
/// Two ways of knowing, and one way of not: the remote shell reported the
/// directory itself, or the host was asked which of its processes belongs to
/// this connection, or neither worked and the panels are left looking wherever
/// an ssh command happens to land.
nonisolated enum RemoteRoot: Equatable, Hashable, Sendable {
    /// The directory the terminal is really in.
    case located(String)

    /// Nowhere in particular: wherever an ssh command lands.
    case loginDirectory
}

extension RemoteRoot {
    /// Where a terminal inside ssh actually is, asked of the host itself.
    ///
    /// `report` is what the remote shell said through OSC 7, if it said
    /// anything: most shells never do, since the integration that emits it
    /// ships switched off unless a particular terminal is recognized.
    /// `connection` describes the terminal's own ssh process, which is what
    /// lets the question be asked anyway.
    ///
    /// Returns nil when the host could not be reached at all, which is not the
    /// same as a host that answered and could not say — the caller keeps what
    /// it had rather than moving the panels.
    ///
    /// Runs off the main actor — every branch is a round trip.
    nonisolated static func locate(
        report: (host: String, path: String)?,
        connection: SSHConnection?,
        on destination: RemoteShellDestination
    ) -> RemoteRoot? {
        if let report {
            // A report has to be placed before it can be believed. The name a
            // shell gives is its own hostname, which is rarely the way the user
            // spelled the destination — an `ssh_config` alias never matches —
            // so a mismatch asks the host what it calls itself rather than
            // throwing the directory away. A shell one ssh further out answers
            // with a third name and is refused: its directory is on a machine
            // this connection does not reach.
            if destination.matches(reportedHost: report.host) { return .located(report.path) }
            guard let name = GitCommand.hostname(of: destination) else { return nil }
            return destination.namesSameHost(reported: report.host, confirmed: name)
                ? .located(report.path) : .loginDirectory
        }
        guard let connection else { return .loginDirectory }
        return GitCommand.shellDirectory(of: connection, on: destination)
    }
}

extension GitCommand {
    /// The directory on `destination` to look for a repository in.
    ///
    /// Runs off the main actor: learning the login directory means asking the
    /// host, which rides the connection the panels already hold open. That
    /// answer is a property of the host rather than of the moment, so it is
    /// asked once per destination.
    nonisolated static func directory(
        for root: RemoteRoot, on destination: RemoteShellDestination
    ) -> GitDirectory {
        switch root {
        case .located(let path):
            return GitDirectory(path, on: destination)
        case .loginDirectory:
            return loginDirectory(on: destination)
        }
    }

    /// The working directory of the shell on `destination` that this ssh
    /// connection is talking to.
    ///
    /// The host is asked to find the process whose `SSH_CONNECTION` names this
    /// connection's ports and read its working directory. That process is the
    /// login shell — the ancestor of everything else the connection started —
    /// and its directory is the one whose name is in the prompt.
    ///
    /// Unlike the login directory this changes with every `cd`, so it is asked
    /// again rather than remembered. It is also the only way to follow a
    /// terminal on a host whose shell has no OSC 7 integration, which is most
    /// of them: the integration that emits it ships disabled unless it
    /// recognizes the terminal it is talking to.
    ///
    /// Returns ``RemoteRoot/loginDirectory`` when the host answered but could
    /// not place the connection — it has no `/proc`, or the shell is inside a
    /// `screen` whose connection is long gone — and nil when it could not be
    /// reached at all.
    nonisolated static func shellDirectory(
        of connection: SSHConnection, on destination: RemoteShellDestination
    ) -> RemoteRoot? {
        // The bound is the ssh process's own age, which the shell on the far
        // side cannot exceed. A little slack for the clocks and for a shell
        // that reports its start time rounded down to the tick.
        let arguments = [String(Int(connection.age) + 10)]
            + connection.ports.prefix(8).map { "\($0.client):\($0.server)" }
        let result = RemoteFileService.execute(
            script: shellDirectoryScript, arguments: arguments,
            maxBytes: 8192, on: destination
        )
        // ssh reports its own failures as 255; anything else came from the
        // script, which means the host answered.
        guard result.status != 255 else { return nil }
        guard result.status == 0 else { return .loginDirectory }
        let path = String(decoding: result.stdout, as: UTF8.self)
        // An absolute path with nothing in it that a terminal could not print:
        // this is about to be shown, and to become the directory Git runs in.
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return .loginDirectory }
        return .located(path)
    }

    /// Finds the process a connection belongs to and prints its working
    /// directory, on a host with a `/proc` — which is to say on Linux.
    ///
    /// One `grep` over every process's environment rather than a shell loop
    /// reading them one at a time: on a busy host that is the difference
    /// between a round trip and a visible pause. `-z` makes the NUL between
    /// environment entries the record separator, so the pattern can anchor to a
    /// whole `SSH_CONNECTION=…` entry.
    ///
    /// Of the processes that match — the shell and everything it started, all
    /// of which inherited the environment — the wanted one is the shell, found
    /// as the one whose parent is not itself a match. Two independent matches
    /// mean the answer is ambiguous, and nothing is better than a guess.
    ///
    /// A `screen` or `tmux` among them gives up rather than answering. The
    /// connection's own shell is then only the one running the client, and the
    /// shell the user is actually typing at belongs to the multiplexer, which
    /// keeps its windows to itself — so the directory that shell is sitting in
    /// would be the wrong one, confidently.
    private nonisolated static let shellDirectoryScript = """
        maxage=$1; shift; \
        [ -d /proc/1 ] || exit 3; \
        for pair in "$@"; do \
        list=$(grep -laz -e \
        "^SSH_CONNECTION=[^ ]* ${pair%%:*} [^ ]* ${pair##*:}$" \
        /proc/[0-9]*/environ 2>/dev/null); \
        [ -n "$list" ] || continue; \
        clock=$(getconf CLK_TCK 2>/dev/null) || clock=; \
        [ -n "$clock" ] || clock=100; \
        uptime=$(cut -d " " -f 1 /proc/uptime); uptime=${uptime%%.*}; \
        found=; \
        for file in $list; do \
        pid=${file#/proc/}; pid=${pid%/environ}; \
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || continue; \
        case "$(cat "/proc/$pid/comm" 2>/dev/null)" in screen*|tmux*) exit 6;; esac; \
        set -- ${stat##*") "}; \
        [ $(( uptime - ${20} / clock )) -le "$maxage" ] || continue; \
        found="$found $pid:$2"; \
        done; \
        shell=; \
        for entry in $found; do \
        case " $found " in *" ${entry#*:}:"*) continue;; esac; \
        [ -z "$shell" ] || exit 5; \
        shell=${entry%:*}; \
        done; \
        [ -n "$shell" ] || continue; \
        cwd=$(readlink "/proc/$shell/cwd" 2>/dev/null) || continue; \
        case "$cwd" in *" (deleted)") continue;; esac; \
        printf "%s" "$cwd"; exit 0; \
        done; \
        exit 4
        """

    /// Where an ssh command lands on `destination`, named rather than left as
    /// `.` so a panel can say which directory it looked in.
    private nonisolated static func loginDirectory(on destination: RemoteShellDestination) -> GitDirectory {
        GitDirectory(cached(\.logins, for: destination) { probe(script: "pwd", on: $0) } ?? ".",
                     on: destination)
    }

    /// What the far side calls itself, for placing a reported directory.
    fileprivate nonisolated static func hostname(of destination: RemoteShellDestination) -> String? {
        cached(\.hostnames, for: destination) { probe(script: "uname -n", on: $0) }
    }

    /// One line of output from a fixed script, or nil when the host could not
    /// be reached or said nothing usable.
    private nonisolated static func probe(script: String, on destination: RemoteShellDestination) -> String? {
        let result = RemoteFileService.execute(
            script: script, arguments: [], maxBytes: 4096, on: destination
        )
        guard result.status == 0 else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Answers held for the life of the process: a host does not rename itself
    /// or move its home directory under a connection, and re-asking would put
    /// a round trip in front of every refresh.
    private nonisolated final class HostFacts: @unchecked Sendable {
        var hostnames: [RemoteShellDestination: String] = [:]
        var logins: [RemoteShellDestination: String] = [:]
    }

    private nonisolated static let facts = HostFacts()
    private nonisolated static let factsLock = NSLock()

    private nonisolated static func cached(
        _ table: ReferenceWritableKeyPath<HostFacts, [RemoteShellDestination: String]>,
        for destination: RemoteShellDestination,
        resolve: (RemoteShellDestination) -> String?
    ) -> String? {
        factsLock.lock()
        let known = facts[keyPath: table][destination]
        factsLock.unlock()
        if let known { return known }
        guard let value = resolve(destination) else { return nil }
        factsLock.lock()
        facts[keyPath: table][destination] = value
        factsLock.unlock()
        return value
    }
}

extension RemoteRoot {
    /// The directory the terminal is in, when the host could say.
    nonisolated var locatedPath: String? {
        switch self {
        case .located(let path): path
        case .loginDirectory: nil
        }
    }
}

/// Where a panel has been pointed: a directory on this Mac, or what is known
/// about where a terminal is on the host it has ssh'd into.
///
/// One type for both so a panel has a single notion of "where I am", and so
/// moving between machines is an ordinary value change the staleness guards
/// already cover.
nonisolated enum PanelRoot: Equatable, Hashable, Sendable {
    case local(String)
    case remote(RemoteRoot, RemoteShellDestination)

    var remote: RemoteShellDestination? {
        if case .remote(_, let destination) = self { return destination }
        return nil
    }

    /// True only for a local panel that has not been pointed anywhere yet.
    var isUnset: Bool {
        if case .local(let path) = self { return path.isEmpty }
        return false
    }

    /// The best name available without asking the host anything — what a
    /// header can show before ``directory()`` has run.
    var provisionalPath: String {
        switch self {
        case .local(let path): path
        case .remote(let root, _): root.locatedPath ?? ""
        }
    }

    /// The directory to actually run Git in. Reaches the host for a remote
    /// panel, so it belongs off the main actor.
    func directory() -> GitDirectory {
        switch self {
        case .local(let path):
            return GitDirectory(path)
        case .remote(let root, let destination):
            return GitCommand.directory(for: root, on: destination)
        }
    }

    /// True when the panel is on a remote host that could not say where the
    /// terminal is, so the repository is looked for wherever an ssh command
    /// lands rather than where the user actually is.
    var isRemoteLoginFallback: Bool {
        if case .remote(let root, _) = self, root.locatedPath == nil { return true }
        return false
    }
}
