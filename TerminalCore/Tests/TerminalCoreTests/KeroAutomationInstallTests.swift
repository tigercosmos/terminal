//
//  KeroAutomationInstallTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Turning on the agents setting writes into the user's home: skill links
/// under `~/.agents` and `~/.claude`, and lifecycle hooks into agent config
/// directories. Every test here builds both the app bundle and the home inside
/// the temporary directory, so none of it touches a real one.
struct KeroAutomationInstallTests {
    private let root: URL
    private let bundle: Bundle
    private let home: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terminal-install-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

        // The app ships these flattened into Contents/Resources, which is the
        // last place the lookups try.
        try "---\nname: terminal-automation\n---\n".write(
            to: resources.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "interface: {}\n".write(
            to: resources.appendingPathComponent("openai.yaml"), atomically: true, encoding: .utf8
        )
        try "// TERMINAL_INTEGRATION_ID=opencode\n".write(
            to: resources.appendingPathComponent("terminal-agent-state.js"),
            atomically: true, encoding: .utf8
        )
        try "// TERMINAL_INTEGRATION_ID=pi\n".write(
            to: resources.appendingPathComponent("terminal-agent-state.pi.txt"),
            atomically: true, encoding: .utf8
        )
        try "{\"_\": \"TERMINAL_INTEGRATION_ID=grok\"}\n".write(
            to: resources.appendingPathComponent("terminal-agent-state.grok.json"),
            atomically: true, encoding: .utf8
        )
        bundle = try #require(Bundle(url: resources))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeSkill: URL {
        home.appendingPathComponent(".claude/skills/terminal-automation", isDirectory: true)
    }

    // MARK: - Skill

    @Test func installingLinksTheSkillForEveryAgentAndIsIdempotent() throws {
        defer { cleanUp() }
        let all = KeroAutomationSkill.Destination.allCases

        let first = try KeroAutomationSkill.install(
            destinations: all, force: false, bundle: bundle, homeURL: home
        )
        #expect(first.map(\.previousState) == [.missing, .missing])
        let skill = try FileManager.default.destinationOfSymbolicLink(
            atPath: claudeSkill.appendingPathComponent("SKILL.md").path
        )
        #expect(skill.hasSuffix("/Resources/SKILL.md"))

        let status = try KeroAutomationSkill.status(destinations: all, bundle: bundle, homeURL: home)
        #expect(status.map(\.state) == [.current, .current])

        let second = try KeroAutomationSkill.install(
            destinations: all, force: false, bundle: bundle, homeURL: home
        )
        #expect(second.map(\.previousState) == [.current, .current])
    }

    /// A user's own edit to the installed skill is theirs: neither enabling
    /// again nor disabling may replace or delete it without `--force`.
    @Test func aLocallyEditedSkillIsLeftAlone() throws {
        defer { cleanUp() }
        _ = try KeroAutomationSkill.install(
            destinations: [.claude], force: false, bundle: bundle, homeURL: home
        )
        let notes = claudeSkill.appendingPathComponent("NOTES.md")
        try "mine".write(to: notes, atomically: true, encoding: .utf8)

        let status = try KeroAutomationSkill.status(destinations: [.claude], bundle: bundle, homeURL: home)
        #expect(status.first?.state == .modified)
        #expect(throws: KeroAutomationSkill.SkillError.self) {
            _ = try KeroAutomationSkill.install(
                destinations: [.claude], force: false, bundle: bundle, homeURL: home
            )
        }
        #expect(throws: KeroAutomationSkill.SkillError.self) {
            _ = try KeroAutomationSkill.uninstall(
                destinations: [.claude], force: false, bundle: bundle, homeURL: home
            )
        }
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test func uninstallingRemovesOnlyWhatWasInstalled() throws {
        defer { cleanUp() }
        let all = KeroAutomationSkill.Destination.allCases
        _ = try KeroAutomationSkill.install(destinations: all, force: false, bundle: bundle, homeURL: home)
        let removed = try KeroAutomationSkill.uninstall(
            destinations: all, force: false, bundle: bundle, homeURL: home
        )
        #expect(removed.map(\.state) == [.missing, .missing])
        #expect(!FileManager.default.fileExists(atPath: claudeSkill.path))
        // The parent the user already had, or that install made, stays.
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/skills").path
        ))
    }

    /// The race the move-then-check exists for: validated as Terminal's, then
    /// changed before the replace or removal reached it. Calling the step
    /// directly with the earlier verdict reproduces that interval.
    @Test func aSkillChangedAfterValidationIsPutBackNotReplaced() throws {
        defer { cleanUp() }
        _ = try KeroAutomationSkill.install(
            destinations: [.claude], force: false, bundle: bundle, homeURL: home
        )
        let notes = claudeSkill.appendingPathComponent("NOTES.md")
        try "written meanwhile".write(to: notes, atomically: true, encoding: .utf8)
        let source = try KeroAutomationSkill.source(bundle: bundle)

        #expect(throws: KeroAutomationSkill.SkillError.self) {
            try KeroAutomationSkill.replaceSkill(at: claudeSkill, source: source, expecting: .current)
        }
        #expect(throws: KeroAutomationSkill.SkillError.self) {
            try KeroAutomationSkill.removeSkill(at: claudeSkill, source: source, expecting: .current)
        }
        #expect(try String(contentsOf: notes, encoding: .utf8) == "written meanwhile")
        // Nothing parked or staged is left beside it.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: claudeSkill.deletingLastPathComponent().path
        )
        #expect(siblings == ["terminal-automation"])
    }

    @Test func aSkillThatAppearedAfterValidationIsNotReplaced() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: claudeSkill, withIntermediateDirectories: true)
        let theirs = claudeSkill.appendingPathComponent("SKILL.md")
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)
        let source = try KeroAutomationSkill.source(bundle: bundle)

        #expect(throws: KeroAutomationSkill.SkillError.self) {
            try KeroAutomationSkill.replaceSkill(at: claudeSkill, source: source, expecting: .missing)
        }
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "theirs")
    }

    // MARK: - Lifecycle integrations

    /// Enabling never creates configuration for an agent the user does not
    /// have; only an existing config directory gets a hook.
    @Test func hooksGoOnlyToAgentsAlreadyInstalled() throws {
        defer { cleanUp() }
        let opencode = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: opencode, withIntermediateDirectories: true)

        try KeroAgentIntegrations.installAvailable(bundle: bundle, homeURL: home, environment: [:])

        let plugin = opencode.appendingPathComponent("plugins/terminal-agent-state.js")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: plugin.path)
        #expect(target.hasSuffix("/Resources/terminal-agent-state.js"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path))

        try KeroAgentIntegrations.uninstallManaged(homeURL: home, environment: [:])
        #expect(!FileManager.default.fileExists(atPath: plugin.path))
        #expect(FileManager.default.fileExists(atPath: opencode.path))
    }

    @Test func aHookFileTheUserWroteIsNeverReplaced() throws {
        defer { cleanUp() }
        let plugins = home.appendingPathComponent(".config/opencode/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let theirs = plugins.appendingPathComponent("terminal-agent-state.js")
        try "export default {}\n".write(to: theirs, atomically: true, encoding: .utf8)

        #expect(throws: KeroAgentIntegrations.IntegrationError.self) {
            try KeroAgentIntegrations.installAvailable(bundle: bundle, homeURL: home, environment: [:])
        }
        #expect(throws: KeroAgentIntegrations.IntegrationError.self) {
            try KeroAgentIntegrations.uninstallManaged(homeURL: home, environment: [:])
        }
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "export default {}\n")
    }

    /// A managed link that a provider's installer swapped for its own file
    /// between the check and the delete: the delete must not take it.
    @Test func aHookReplacedAfterValidationIsPutBack() throws {
        defer { cleanUp() }
        let plugins = home.appendingPathComponent(".config/opencode/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let hook = plugins.appendingPathComponent("terminal-agent-state.js")
        try "export default {}\n".write(to: hook, atomically: true, encoding: .utf8)

        #expect(throws: KeroAgentIntegrations.IntegrationError.self) {
            try KeroAgentIntegrations.removeManaged(at: hook, kind: .opencode)
        }
        #expect(throws: KeroAgentIntegrations.IntegrationError.self) {
            try KeroAgentIntegrations.replaceWithLink(
                at: hook, sourceURL: bundle.bundleURL.appendingPathComponent("terminal-agent-state.js"),
                kind: .opencode
            )
        }
        #expect(try String(contentsOf: hook, encoding: .utf8) == "export default {}\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: plugins.path)
            == ["terminal-agent-state.js"])
    }

    /// Pi and Grok honor a configured home; the hook follows it.
    @Test func aConfiguredAgentHomeIsRespected() throws {
        defer { cleanUp() }
        let piHome = root.appendingPathComponent("pi-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: piHome, withIntermediateDirectories: true)

        try KeroAgentIntegrations.installAvailable(
            bundle: bundle, homeURL: home, environment: ["PI_CODING_AGENT_DIR": piHome.path]
        )
        #expect(FileManager.default.fileExists(
            atPath: piHome.appendingPathComponent("extensions/terminal-agent-state.ts").path
        ))
    }
}
