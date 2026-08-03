//
//  TerminalSession.swift
//  terminal
//

import AppKit
import Combine
import Darwin
import Foundation
import TerminalCore

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; a CLI-created project can instead
/// exec an explicit argv directly. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and split-layout changes.
///
/// Which emulator draws that surface is `TerminalBackend`'s business: this
/// type talks to ``TerminalBackendSurface`` and hears back through
/// ``TerminalBackendEvents``, and names no emulator's types itself.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var title: String
    @Published var workingDirectory: String?
    /// The host a shell named in its OSC 7 report, when that host is not this
    /// machine. Set only by the Alacritty backend: libghostty drops a report
    /// from another host before Terminal ever sees it, which is why a remote
    /// session is recognized from the process tree instead — see
    /// ``remoteDestination``.
    @Published private(set) var remoteHost: String?
    /// The directory that remote shell last reported, paired with
    /// ``remoteHost``. Never a path on this machine.
    @Published private(set) var remoteWorkingDirectory: String?

    @Published var hasExited = false
    @Published private(set) var commandLifecycle = TerminalCommandLifecycle()

    /// The emulator driving this session. Fixed for the session's lifetime —
    /// changing the setting only affects terminals opened afterwards.
    let backend: TerminalBackend
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    /// How long an established remote location is used before the host is
    /// asked again. Matches the panels' own refresh, so following a `cd` costs
    /// no more delay than the panels already have.
    private static let remoteLocationLifetime: TimeInterval = 2

    /// Where this terminal was last established to be on the host it has ssh'd
    /// into, and when — see ``remoteRoot(on:)``.
    private struct RemoteLocation {
        let destination: RemoteShellDestination
        let root: RemoteRoot
        let asOf: Date
    }

    /// Deliberately not published: it is refreshed on a timer, and the panels
    /// that read it are already driven by that same timer. Publishing it would
    /// redraw every view watching this session twice a second for a value most
    /// of them never look at.
    private var remoteLocation: RemoteLocation?
    private var isLocating = false

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var lastHistorySnapshot: String?
    private var isTerminating = false
    private var commandExecutionStartedAtNanos: UInt64?

    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil
    ) {
        let directCommand = commandArguments.flatMap { $0.isEmpty ? nil : $0 }
        let shellPath = directCommand?.first ?? Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
        let backend = AppSettings.shared.terminalBackend
        let script = Self.makeLaunchScript(
            backend: backend,
            shellPath: shellPath,
            commandArguments: directCommand,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL
        )
        let launch = TerminalLaunch(
            program: "/bin/sh",
            arguments: ["-c", script],
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            workingDirectory: directory,
            environment: Self.surfaceEnvironment(pathOverride: environmentPath)
        )

        self.shellPath = shellPath
        self.backend = backend
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent

        let surface = Self.makeSurface(backend: backend, launch: launch)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        surface.events = self
        installOverlayScrollbar()
        applyTheme()
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    /// `makeSurface` returns nil only for a backend this build has no surface
    /// for, and `AppSettings` refuses to store one — so this is belt and
    /// braces, preferring a working terminal over an empty pane.
    private static func makeSurface(
        backend: TerminalBackend, launch: TerminalLaunch
    ) -> any TerminalBackendSurface {
        if let surface = backend.makeSurface(launch: launch) { return surface }
        NSLog("terminal: no surface for terminal backend \(backend.rawValue)")
        return GhosttyTerminalView(launch: launch)
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Reconfigures the surface in place when either appearance or terminal
    /// font settings change.
    func applyTheme() {
        surface.applyAppearance()
    }

    /// Stops the whole PTY job before releasing the surface. The backend's
    /// teardown owns the final reap; sending HUP first gives shells the same
    /// close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Detaching first can make a backend wait
    /// synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        // TerminalHostView normally clears these while dismantling, but close
        // teardown must not depend on a later SwiftUI reconciliation pass.
        // Both callbacks originate on PaneView and capture this session.
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.splitTarget.onSplit = nil
        surface.splitTarget.onNewBrowserTab = nil
        surface.splitTarget.onNewBrowserPane = nil

        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from the backend's
                // process-close callback.
                await Task.yield()
            }
            surface.detach()
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = surface.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        guard let foreground = surface.foregroundPid, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    /// The ssh connection this terminal's foreground job *is*, when it is one.
    ///
    /// Read from the process every time rather than remembered: the user can
    /// leave a remote host at any moment, and a remembered destination would
    /// leave the Files panel describing a machine the terminal is no longer on.
    var remoteDestination: RemoteShellDestination? {
        guard let foreground = surface.foregroundPid, foreground > 0, foreground != shellPid
        else { return nil }
        return remoteShellDestination(foregroundPid: foreground)
    }

    func sendCommand(_ text: String) {
        surface.sendText(text)
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && surface.foregroundPid == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    // MARK: - Launch

    private static func surfaceEnvironment(pathOverride: String?) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            TerminalCLIService.shared.terminalEnvironment,
            uniquingKeysWith: { _, cliValue in cliValue }
        )
        if let pathOverride, !pathOverride.isEmpty {
            environment["PATH"] = pathOverride
        }
        // Locale belongs to the user's shell environment. Terminal's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
    }

    private static func makeLaunchArtifacts(restoredHistory: String?) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("terminal-session-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("terminal: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil)
        }
    }

    /// The `sh` script every pane starts with: record the process PID, replay
    /// any restored scrollback, advertise the emulator, then become either the
    /// requested argv or the user's login shell.
    private static func makeLaunchScript(
        backend: TerminalBackend,
        shellPath: String,
        commandArguments: [String]?,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // Many terminal tools use TERM_PROGRAM as a capability hint. Each
        // backend advertises a compatible identity so tools select protocols
        // that Terminal can actually render.
        let termProgram = backend.termProgram
        commands.append("export TERM_PROGRAM=\(shellQuote(termProgram.name))")
        if !termProgram.version.isEmpty {
            commands.append(
                "export TERM_PROGRAM_VERSION=\(shellQuote(termProgram.version))"
            )
        } else {
            commands.append("unset TERM_PROGRAM_VERSION")
        }
        if let commandArguments {
            let argv = commandArguments.map(shellQuote).joined(separator: " ")
            // `env` resolves argv[0] against the caller's PATH. Every argument
            // is quoted independently, so no command text is reparsed or
            // expanded by the launch shim.
            commands.append("exec /usr/bin/env -- \(argv)")
        } else {
            commands.append("exec \(shellQuote(shellPath)) -l")
        }
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    /// A backend reports `host\0path` when OSC 7 named a machine, and the bare
    /// path otherwise.
    ///
    /// A path from another machine must not become this session's working
    /// directory. That value is where a new tab opens and what a restored
    /// session reopens — both local, and both of which would land on whatever
    /// happens to sit at the same path here. It is kept separately instead, as
    /// one of the ways ``remoteRoot(on:)`` follows the panels onto the host the
    /// terminal is really working on.
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        let fields = path.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
        let reported = fields.count == 2 ? String(fields[1]) : path
        // A name that is not this machine's is not enough on its own to
        // believe the shell is elsewhere. A shell captures its own hostname
        // when it starts and macOS renames a machine out from under it — on a
        // new network, or from System Settings — so a mismatch is at least as
        // likely to be this Mac under a name it no longer uses. Taking that
        // for a remote report would leave a perfectly local terminal's
        // directory frozen at wherever it was when the machine was renamed.
        // Being inside ssh is the fact that settles it.
        if fields.count == 2, !isLocalHostname(String(fields[0])), remoteDestination != nil {
            remoteHost = String(fields[0])
            remoteWorkingDirectory = reported
            return
        }
        remoteHost = nil
        remoteWorkingDirectory = nil
        workingDirectory = reported.hasPrefix("/")
            ? URL(fileURLWithPath: reported).absoluteString : reported
    }

    func terminalDidRingBell() {
        NSSound.beep()
        guard !surface.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(message: String(localized: "Terminal bell"))
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message)
    }

    /// Schemes a terminal link may open without asking. Everything else is
    /// handed to LaunchServices only after the user has seen the real target.
    private static let autoOpenableURLSchemes: Set<String> = [
        "http", "https", "mailto",
    ]

    /// Opens a link clicked in the terminal.
    ///
    /// The text of an OSC 8 hyperlink is chosen independently of its target, so
    /// a link reading `https://github.com/…` can carry a `file://` URL that
    /// LaunchServices would happily hand to an application. Terminal output is
    /// untrusted — it comes from remote hosts, files, and agents — so anything
    /// outside ``autoOpenableURLSchemes`` is confirmed against the URL Terminal
    /// would actually open rather than the text that was clicked.
    func terminalDidRequestOpenURL(_ url: String) {
        guard let target = URL(string: url),
              let scheme = target.scheme?.lowercased()
        else { return }

        if Self.autoOpenableURLSchemes.contains(scheme) {
            NSWorkspace.shared.open(target)
            return
        }
        confirmOpen(target)
    }

    private func confirmOpen(_ target: URL) {
        guard let window = surface.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Warning: Potentially Unsafe Link")
        alert.informativeText = String(
            localized: "This link opens outside your browser, so it may launch an application. The link text in the terminal can differ from where it actually leads; the real destination is shown below."
        )
        alert.accessoryView = Self.clipboardPreview(target.absoluteString)
        alert.addButton(withTitle: String(localized: "Open Link"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(target)
        }
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste")
            : String(localized: "Allow"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel")
                : String(localized: "Deny")
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    /// Bounded, read-only preview of the text under decision — clipboard
    /// contents or a link target — mirroring the preview area in Ghostty's own
    /// confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = visibleControlCharacters(in: String(contents.prefix(4096)))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }

    /// Renders C0/C1 control characters as their Control Pictures glyphs.
    ///
    /// The point of this sheet is that the user approves what will actually be
    /// sent. An escape character draws as nothing, so text carrying a bracketed
    /// paste terminator or a cursor-movement sequence would otherwise preview as
    /// something quite different from what the terminal receives.
    private static func visibleControlCharacters(in contents: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in contents.unicodeScalars {
            switch scalar.value {
            // Line breaks and tabs are the shape of the text, not hidden state.
            case 0x09, 0x0a:
                output.append(scalar)
            case 0x0d:
                // A lone CR would redraw over the line it previews.
                output.append(Unicode.Scalar(0x240d)!)
            case 0x00...0x1f:
                output.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7f:
                output.append(Unicode.Scalar(0x2421)!)
            case 0x80...0x9f:
                // No pictures exist for C1; mark them rather than drop them.
                output.append(contentsOf: "\u{fffd}".unicodeScalars)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }
}

extension TerminalSession {
    /// Where this terminal is on `destination`, as last established.
    ///
    /// Answers from what is already known and starts a fresh enquiry when that
    /// has gone stale, because establishing it means asking the host and the
    /// main actor cannot wait on a network round trip. Files, Git and Compare
    /// all ask this, so asking it once here — rather than in each panel — is
    /// also one question per few seconds instead of three.
    func remoteRoot(on destination: RemoteShellDestination) -> RemoteRoot {
        locateIfStale(on: destination)
        guard let remoteLocation, remoteLocation.destination == destination else {
            return .loginDirectory
        }
        return remoteLocation.root
    }

    /// Asks the host where this terminal is, unless a recent answer already
    /// covers it or an enquiry is already out.
    ///
    /// The answer expires because the user is free to `cd`: this is the panels'
    /// only way of noticing on a host whose shell reports nothing, and two
    /// seconds is the same cadence the panels themselves refresh on.
    private func locateIfStale(on destination: RemoteShellDestination) {
        guard !isLocating else { return }
        if let remoteLocation, remoteLocation.destination == destination,
           Date().timeIntervalSince(remoteLocation.asOf) < Self.remoteLocationLifetime {
            return
        }
        // Read on the actor that owns them, so the enquiry carries values
        // rather than a reference to this session.
        let report = remoteHost.flatMap { host in
            remoteWorkingDirectory.map { (host: host, path: $0) }
        }
        let connection = surface.foregroundPid.flatMap { sshConnection(pid: $0) }
        isLocating = true
        Task.detached(priority: .utility) { [weak self] in
            let root = RemoteRoot.locate(
                report: report, connection: connection, on: destination
            )
            await self?.located(root, on: destination)
        }
    }

    /// Takes the answer to an enquiry, or the lack of one.
    private func located(_ root: RemoteRoot?, on destination: RemoteShellDestination) {
        isLocating = false
        let previous = remoteLocation?.destination == destination ? remoteLocation?.root : nil
        // A host that could not be reached at all keeps the last known
        // directory: a connection that blinked is not a terminal that moved.
        // The timestamp moves either way, so an unreachable host is asked again
        // on the next expiry rather than on every tick.
        remoteLocation = RemoteLocation(
            destination: destination, root: root ?? previous ?? .loginDirectory, asOf: Date()
        )
    }
}
