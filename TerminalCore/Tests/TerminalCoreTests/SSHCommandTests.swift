//
//  SSHCommandTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

struct SSHCommandTests {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    @Test func inheritedPipesCannotOutliveTheTimeout() {
        // The parent succeeds immediately; its child holds the pipes open.
        // Killing only the parent cannot unblock a readDataToEndOfFile reader.
        let process = shell("sleep 4 & exit 0")
        let start = ContinuousClock.now
        let result = RemoteFileService.capture(process, timeout: 0.2)
        #expect(result.status == RemoteFileService.timedOutStatus)
        #expect(!result.stderr.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func ignoredTerminationIsEscalatedAndReported() {
        let process = shell("trap '' TERM; exec sleep 5")
        let start = ContinuousClock.now
        let result = RemoteFileService.capture(process, timeout: 0.1)
        #expect(result.status == RemoteFileService.timedOutStatus)
        #expect(!result.stderr.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func bothStreamsDrainWhileStdinExceedsThePipeBuffer() {
        let payload = Data(repeating: 65, count: 256 * 1024)
        let process = shell("cat; printf 'diagnostic' >&2")
        let result = RemoteFileService.capture(process, maxBytes: 1024, input: payload, timeout: 3)
        #expect(result.status == 0)
        #expect(result.stdout.count == 1025)
        #expect(result.stderr == "diagnostic")
    }

    @Test func cshLoginCanRunProbeAndInstallWithoutMultilineArguments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = RemoteShellDestination(destination: "test", reachOptions: [])
        let source = Data(try RemoteAgent.helperSource().utf8)
        for (script, arguments) in [(RemoteAgent.probeScript, ["30", "1:1"]),
                                    (RemoteAgent.installScript, ["claude"])] {
            let command = try #require(RemoteFileService.sshInvocation(
                script: script, arguments: arguments, on: destination
            ).last)
            #expect(!command.contains("\n"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/csh")
            process.arguments = ["-f", "-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, value in value }
            let result = RemoteFileService.capture(process, input: source, timeout: 10)
            #expect(result.status == 0, "\\(result.stderr)")
        }
    }
}
