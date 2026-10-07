//
//  KeroAgentKind.swift
//  TerminalCore
//

import Darwin
import Foundation

/// A coding agent CLI that pane and agent automation recognizes.
///
/// Recognition reads the foreground process's kernel-reported executable and
/// argv, never the tab title or rendered output: both of those are terminal
/// text the program itself controls.
public nonisolated enum KeroAgentKind: String, CaseIterable, Codable, Sendable {
    case codex
    case claude
    case gemini
    case grok
    case opencode
    case cursor = "cursor-agent"
    case aider
    case amp
    case pi

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok Build"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .aider: return "Aider"
        case .amp: return "Amp"
        case .pi: return "Pi"
        }
    }

    public var executable: String { rawValue }

    public static func recognize(processID: pid_t) -> Self? {
        guard processID > 0 else { return nil }
        return recognize(
            executablePath: processExecutablePath(pid: processID),
            arguments: processArguments(pid: processID) ?? []
        )
    }

    public static func recognize(
        executablePath: String?,
        arguments: [String] = []
    ) -> Self? {
        // argv[0] preserves the invoked symlink for versioned native installs
        // such as Claude and `exec -a` wrappers such as Cursor Agent.
        for value in [arguments.first, executablePath].compactMap({ $0 }) {
            if let kind = recognizeCommandName(value) { return kind }
        }

        guard let executablePath,
              isScriptInterpreter((executablePath as NSString).lastPathComponent)
        else { return nil }

        let tail = Array(arguments.dropFirst().prefix(8))
        if let moduleFlag = tail.firstIndex(of: "-m"),
           tail.indices.contains(moduleFlag + 1),
           let kind = recognizeScriptIdentity(tail[moduleFlag + 1]) {
            return kind
        }

        // For the supported wrappers the first non-option operand identifies
        // the script. Stop there rather than scanning prompts or user paths,
        // which would make ordinary interpreter jobs look like agents.
        for value in tail {
            if value.hasPrefix("-") || value == "run" { continue }
            return recognizeScriptIdentity(value)
        }
        return nil
    }

    private static func recognizeCommandName(_ value: String) -> Self? {
        var name = (value as NSString).lastPathComponent.lowercased()
        for suffix in [".exe", ".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        if name == "grok" || name == "xai-grok-pager" {
            return .grok
        }
        // Official installs resolve `~/.grok/bin/grok` to a versioned binary
        // such as `grok-1.0.0-macos-aarch64`; foreground PID inspection sees
        // that target even though argv[0] usually preserves the `grok` link.
        if name.hasPrefix("grok-"),
           name.contains("-macos-") || name.contains("-linux-") {
            return .grok
        }
        switch name {
        case "codex": return .codex
        case "claude": return .claude
        case "gemini": return .gemini
        case "opencode": return .opencode
        case "cursor-agent": return .cursor
        case "aider", "aider-chat": return .aider
        case "amp": return .amp
        case "pi": return .pi
        default: return nil
        }
    }

    private static func isScriptInterpreter(_ value: String) -> Bool {
        let name = value.lowercased()
        return name == "node" || name == "nodejs" || name == "bun"
            || name == "deno" || name == "python" || name.hasPrefix("python3")
            || name == "ruby" || name == "bash" || name == "sh" || name == "zsh"
    }

    private static func recognizeScriptIdentity(_ value: String) -> Self? {
        if let kind = recognizeCommandName(value) { return kind }
        let normalized = value.lowercased().replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("/@openai/codex/") { return .codex }
        if normalized.contains("/@anthropic-ai/claude-code/") { return .claude }
        if normalized.contains("/gemini-cli/") { return .gemini }
        if normalized.contains("/grok-dev/") { return .grok }
        if normalized.contains("/opencode-ai/") { return .opencode }
        if normalized.contains("/cursor-agent/") { return .cursor }
        if normalized.contains("/aider-chat/") || normalized.contains("/aider_chat/") {
            return .aider
        }
        if normalized.contains("/sourcegraph/amp/") { return .amp }
        if normalized.contains("/pi-coding-agent/") { return .pi }
        return nil
    }
}
