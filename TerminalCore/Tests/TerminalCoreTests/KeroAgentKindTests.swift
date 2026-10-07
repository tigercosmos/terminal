//
//  KeroAgentKindTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Agent recognition decides which terminals get a status badge and which
/// accept a guarded prompt, so a miss hides an agent and a false match lets
/// automation type a prompt into an ordinary program.
struct KeroAgentKindTests {
    @Test func aNativeInstallIsRecognizedByItsCommandName() {
        #expect(KeroAgentKind.recognize(executablePath: "/opt/homebrew/bin/codex") == .codex)
        #expect(KeroAgentKind.recognize(executablePath: "/usr/local/bin/cursor-agent") == .cursor)
        #expect(KeroAgentKind.recognize(executablePath: "/Users/me/.local/bin/aider-chat") == .aider)
    }

    /// Claude installs a versioned binary behind a symlink; argv[0] keeps the
    /// name the shell ran even though the kernel reports the target.
    @Test func argvZeroWinsOverAVersionedImage() {
        let kind = KeroAgentKind.recognize(
            executablePath: "/Users/me/.local/share/claude/versions/2.1.0",
            arguments: ["claude", "--resume"]
        )
        #expect(kind == .claude)
    }

    @Test func aVersionedGrokBinaryIsStillGrok() {
        #expect(KeroAgentKind.recognize(
            executablePath: "/Users/me/.grok/bin/grok-1.0.0-macos-aarch64"
        ) == .grok)
    }

    @Test func aScriptBehindAnInterpreterIsRecognizedByItsPackage() {
        let codex = KeroAgentKind.recognize(
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"]
        )
        #expect(codex == .codex)

        let aider = KeroAgentKind.recognize(
            executablePath: "/usr/bin/python3",
            arguments: ["python3", "-m", "aider"]
        )
        #expect(aider == .aider)
    }

    /// Only the script operand identifies a wrapper. A later argument that
    /// happens to mention an agent — a prompt, a path — must not turn an
    /// ordinary interpreter job into one.
    @Test func laterArgumentsAreNotScanned() {
        let kind = KeroAgentKind.recognize(
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "server.js", "--config", "/tmp/@openai/codex/x.json"]
        )
        #expect(kind == nil)
    }

    @Test func anOrdinaryProgramIsNoAgent() {
        #expect(KeroAgentKind.recognize(executablePath: "/usr/bin/vim", arguments: ["vim"]) == nil)
        #expect(KeroAgentKind.recognize(executablePath: nil) == nil)
    }

    /// This test process is no agent, and a pid that cannot exist resolves to
    /// nothing rather than to whatever argv happened to be read last.
    @Test func liveProcessesAreReadFromTheKernel() {
        #expect(KeroAgentKind.recognize(processID: getpid()) == nil)
        #expect(KeroAgentKind.recognize(processID: 0) == nil)
        #expect(processExecutablePath(pid: getpid()) != nil)
        #expect(processArguments(pid: getpid())?.isEmpty == false)
    }
}
