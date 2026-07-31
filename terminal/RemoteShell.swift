//
//  RemoteShell.swift
//  terminal
//

import Darwin
import Foundation

/// An ssh connection a terminal session is sitting inside, described well
/// enough for Terminal to reach the same host itself.
///
/// Terminal cannot ask the user's own ssh process to run anything — it is busy
/// being their shell — so the panels open a second connection to the same
/// place. What keeps that from being a second login is connection
/// multiplexing; see ``RemoteFileService``.
struct RemoteShellDestination: Equatable, Hashable, Sendable {
    /// The destination operand exactly as the user wrote it: a bare host, a
    /// `user@host`, or an alias their `ssh_config` resolves.
    let destination: String

    /// The part of the user's own ssh command line that decides *which* host
    /// is reached and how it authenticates. Options that shape the interactive
    /// session instead — a forwarded port, a pseudo-terminal, a background
    /// master — are dropped: they do nothing for a one-shot command, and `-N`
    /// would refuse to run one at all.
    let reachOptions: [String]

    /// The hostname alone, for the panel header. Best-effort: an `ssh_config`
    /// alias is shown as the user typed it, since only ssh knows what it
    /// resolves to.
    var host: String {
        var value = destination
        var hasScheme = false
        if let scheme = value.range(of: "://") {
            value = String(value[scheme.upperBound...])
            hasScheme = true
        }
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        // Only the URI form carries a port or a path; `ssh host:22` is not a
        // thing, so a colon in a bare destination belongs to an IPv6 literal.
        guard hasScheme else { return value }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if !value.hasPrefix("["), let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value
    }

    /// Whether `reportedHost` — a hostname a shell put in its OSC 7 report —
    /// names this destination. The remote shell knows its own hostname, which
    /// is rarely spelled the way the user spelled the destination: one side
    /// may be fully qualified and the other not, and either may be an alias.
    /// Matching the first label is the most that can be claimed without
    /// resolving names, and a false match only means the panels believe a
    /// directory the remote shell reported, which is where they are pointed
    /// anyway.
    func matches(reportedHost: String) -> Bool {
        func firstLabel(_ name: String) -> Substring {
            name.prefix { $0 != "." }
        }
        let reported = firstLabel(reportedHost)
        return !reported.isEmpty
            && reported.compare(firstLabel(host), options: .caseInsensitive) == .orderedSame
    }
}

/// The ssh connection a terminal's foreground job *is*, if it is one.
///
/// Terminal recognizes a remote session by looking at the process rather than
/// by trusting shell integration: OSC 7 needs the remote shell to be set up
/// for it, and libghostty drops a report whose host is not this machine, so a
/// terminal that has plainly been sitting on another host for an hour may
/// never have said so.
///
/// The executable is the one the kernel says the process is running, not
/// `argv[0]`: a process can write anything it likes into its own argument
/// vector, and these arguments are about to be reused to open a network
/// connection. The arguments themselves come from a command the user ran in
/// their own shell, and are only ever passed to ssh as an argument vector —
/// never through a shell of Terminal's own.
func remoteShellDestination(foregroundPid pid: pid_t) -> RemoteShellDestination? {
    guard pid > 0,
          let executable = processExecutablePath(pid: pid),
          (executable as NSString).lastPathComponent == "ssh",
          let arguments = processArguments(pid: pid)
    else { return nil }
    return parseSSHArguments(arguments)
}

/// Whether `name` — a hostname from an OSC 7 report — names this machine.
///
/// Compared on the first label alone: a shell writes whatever `hostname` gave
/// it, which may be fully qualified when the local answer is not, or the other
/// way round. Read fresh rather than cached because macOS renames a machine
/// out from under itself when it joins a network, and a stale answer would
/// leave a perfectly local shell looking like a remote one.
func isLocalHostname(_ name: String) -> Bool {
    let reported = name.prefix { $0 != "." }
    guard !reported.isEmpty else { return true }
    if reported.compare("localhost", options: .caseInsensitive) == .orderedSame { return true }
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return false }
    let local = String(cString: buffer).prefix { $0 != "." }
    return !local.isEmpty && reported.compare(local, options: .caseInsensitive) == .orderedSame
}

// MARK: - ssh command line

/// ssh options that take a value, whether glued to the letter (`-p22`) or
/// standing as the next argument (`-p 22`). Needed in full even for options
/// Terminal discards, because skipping a value-taking option's value wrongly
/// would make the next argument look like the destination.
private let sshOptionsWithValue: Set<Character> = [
    "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m",
    "O", "o", "P", "p", "Q", "R", "S", "W", "w",
]

/// Value-taking options worth repeating on Terminal's own connection: the
/// identity, the config file, the port, the login name, the jump host, and
/// whatever `-o` settings the user needed to reach the host at all.
private let sshReachOptionsWithValue: Set<Character> = [
    "B", "b", "c", "F", "I", "i", "J", "l", "m", "o", "p", "S",
]

/// Valueless options worth repeating. `-A` is deliberately absent: forwarding
/// the agent is a grant to the remote host, not a way of reaching it, and
/// Terminal should not extend one the user did not ask it to.
private let sshReachFlags: Set<Character> = ["4", "6", "C"]

/// Splits an ssh argument vector into the destination and the options that
/// reach it. Returns nil when there is no destination operand — `ssh -V`, or
/// a command line Terminal could not follow.
private func parseSSHArguments(_ arguments: [String]) -> RemoteShellDestination? {
    var reachOptions: [String] = []
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        index += 1

        if argument == "--" {
            guard index < arguments.count else { return nil }
            return RemoteShellDestination(
                destination: arguments[index], reachOptions: reachOptions
            )
        }
        guard argument.hasPrefix("-"), argument.count > 1 else {
            // The first operand is the destination. Anything after it is a
            // command for the remote host, which is none of Terminal's business.
            return RemoteShellDestination(destination: argument, reachOptions: reachOptions)
        }

        let letters = Array(argument.dropFirst())
        var position = 0
        while position < letters.count {
            let letter = letters[position]
            position += 1
            guard sshOptionsWithValue.contains(letter) else {
                if sshReachFlags.contains(letter) {
                    reachOptions.append("-\(letter)")
                }
                continue
            }
            let glued = String(letters[position...])
            let value: String
            if glued.isEmpty {
                guard index < arguments.count else { return nil }
                value = arguments[index]
                index += 1
            } else {
                value = glued
            }
            // A value consumes the rest of the cluster either way.
            position = letters.count
            if sshReachOptionsWithValue.contains(letter) {
                reachOptions.append(contentsOf: ["-\(letter)", value])
            }
        }
    }
    return nil
}

// MARK: - Process metadata

/// The executable a process is running, from kernel metadata.
private func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

/// A process's argument vector, from kernel metadata.
///
/// `KERN_PROCARGS2` hands back a counted blob: the argument count, then the
/// executable path, then NUL padding, then the arguments themselves. Only
/// same-user processes are readable, which is every process Terminal spawns.
private func processArguments(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }

    let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard count > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }

    var arguments: [String] = []
    var start = index
    while index < size, arguments.count < count {
        if buffer[index] == 0 {
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            start = index + 1
        }
        index += 1
    }
    return arguments.count == count ? arguments : nil
}
