//
//  CodexIntegrationInstaller.swift
//  terminal
//

import Combine
import Foundation
import TerminalCore

/// Installs and removes Codex's lifecycle plugin by running the user's own
/// `codex`, the only way Codex takes a plugin (see `KeroCodexPlugin`).
///
/// It runs off the main thread and after the agents setting has changed,
/// because finding `codex` means starting the user's login shell, and Codex
/// itself takes a few seconds. A failure is published for Settings to show
/// rather than thrown: the setting's other integrations already succeeded,
/// and Codex missing from this Mac is the common, harmless case.
@MainActor
final class CodexIntegrationInstaller: ObservableObject {
    static let shared = CodexIntegrationInstaller()

    /// Why the last install or removal did not finish, if it did not.
    @Published private(set) var problem: String?

    private var running: Task<Void, Never>?

    private init() {}

    /// `enabled` is the setting's new value. A later call waits for an
    /// earlier one, so toggling quickly never runs `codex` twice at once.
    func reconcile(enabled: Bool) {
        let previous = running
        running = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) {
                enabled ? Self.install() : Self.uninstall()
            }.value
            self?.problem = outcome
            if let outcome { NSLog("terminal: Codex integration: \(outcome)") }
        }
    }

    // MARK: - Work, off the main actor

    private nonisolated static func install() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = KeroCodexPlugin.codexHome(
            homeURL: FileManager.default.homeDirectoryForCurrentUser, environment: environment
        )
        // Like the other integrations: nothing is created for an agent the
        // user does not have.
        guard isDirectory(codexHome) else { return nil }
        let hooks: Data
        do {
            hooks = try KeroCodexPlugin.bundledHooks()
        } catch {
            return error.localizedDescription
        }
        // Current includes a plugin the user switched off in Codex itself:
        // that is their call, and re-enabling it on every launch would undo it.
        if KeroCodexPlugin.isCurrent(codexHome: codexHome, hooks: hooks) { return nil }
        do {
            try KeroCodexPlugin.writeMarketplace(at: marketplaceURL, hooks: hooks)
        } catch {
            return String(
                localized: "Terminal could not prepare its Codex plugin: \(error.localizedDescription)",
                comment: "Shown in Settings → Agents. Placeholder: the system's description of a file error."
            )
        }
        return runCodex(KeroCodexPlugin.installArguments(marketplace: marketplaceURL))
    }

    private nonisolated static func uninstall() -> String? {
        let codexHome = KeroCodexPlugin.codexHome(
            homeURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        guard KeroCodexPlugin.isInstalled(codexHome: codexHome) else {
            try? FileManager.default.removeItem(at: marketplaceURL)
            return nil
        }
        // Both steps run even when the first fails: a plugin Codex no longer
        // lists still leaves its marketplace entry. The folder Codex installs
        // from goes only once Codex has let go of it, so a removal that fails
        // here can be retried at the next launch.
        let problem = runCodex(KeroCodexPlugin.uninstallArguments, stopAtFailure: false)
        if problem == nil { try? FileManager.default.removeItem(at: marketplaceURL) }
        return problem
    }

    /// Runs each `codex` invocation in turn, returning the first failure.
    private nonisolated static func runCodex(
        _ invocations: [[String]],
        stopAtFailure: Bool = true
    ) -> String? {
        guard let path = loginShellPath(),
              let codex = KeroCodexPlugin.executable(named: "codex", onPath: path)
        else {
            return String(
                localized: "Codex is set up on this Mac, but Terminal could not find the `codex` command in your login shell’s PATH, so its Codex hooks were not changed.",
                comment: "Shown in Settings → Agents when Codex's config folder exists but its command cannot be found."
            )
        }
        var environment = ProcessInfo.processInfo.environment
        // `codex` from npm is a Node script; Node is found on the same PATH.
        environment["PATH"] = path
        var firstProblem: String?
        for arguments in invocations {
            let result = run(codex, arguments: arguments, environment: environment, timeout: 60)
            guard result.status == 0 else {
                // The last lines say why; the rest is noise in a Settings note.
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").suffix(3).joined(separator: "\n")
                firstProblem = firstProblem ?? String(
                    localized: "`codex \(arguments.joined(separator: " "))` failed: \(detail)",
                    comment: "Shown in Settings → Agents. Placeholders: the arguments Terminal passed to the codex command, then that command's own output."
                )
                if stopAtFailure { break }
                continue
            }
        }
        return firstProblem
    }

    /// The PATH the user's shell sets up, which a GUI app does not inherit.
    /// Interactive as well as login, since version managers such as nvm are
    /// usually loaded from the interactive rc file. Only the PATH is taken;
    /// asking the shell for `codex` itself can return an alias.
    private nonisolated static func loginShellPath() -> String? {
        let shell = loginShell()
        let marker = "TERMINAL-LOGIN-PATH"
        let script = URL(fileURLWithPath: shell).lastPathComponent == "fish"
            ? "echo \(marker); string join : $PATH"
            : "printf '%s\\n%s\\n' \(marker) \"$PATH\""
        let result = run(
            URL(fileURLWithPath: shell), arguments: ["-l", "-i", "-c", script],
            environment: ProcessInfo.processInfo.environment, timeout: 15
        )
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.lastIndex(where: { $0 == marker }),
              lines.indices.contains(index + 1)
        else { return nil }
        let path = String(lines[index + 1])
        return path.isEmpty ? nil : path
    }

    private nonisolated static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private nonisolated static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // No terminal and no input: a shell or `codex` that wants to ask
        // something gets end-of-file instead of waiting forever.
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Set before `run()`, so an exit that comes at once is never missed.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        // Read as it arrives, so a chatty shell cannot fill the pipe and
        // stall, and so the read never waits on the pipe's last writer: a
        // daemon an rc file started can hold it open long after the shell.
        let output = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // An interactive shell ignores SIGTERM; give it a moment, then
            // SIGKILL, which nothing ignores.
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return (-1, String(localized: "It did not finish in \(Int(timeout)) seconds.", comment: "Why a command Terminal ran for its Codex integration failed. Placeholder: a number of seconds."))
        }
        // Whatever was written just before the exit is still in flight.
        Thread.sleep(forTimeInterval: 0.1)
        return (process.terminationStatus, output.text)
    }

    /// Terminal's own folder, apart from Codex's: the marketplace Codex
    /// installs from. Shared by debug and release builds, since both write
    /// the same files and Codex keys the marketplace by name.
    private nonisolated static var marketplaceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("terminal/codex-marketplace", isDirectory: true)
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Collects a process's output from the pipe's handler thread. Bounded:
/// only the tail is ever shown, in a Settings note.
private nonisolated final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 64 * 1_024 { data = data.suffix(16 * 1_024) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data.suffix(16 * 1_024), as: UTF8.self)
    }
}
