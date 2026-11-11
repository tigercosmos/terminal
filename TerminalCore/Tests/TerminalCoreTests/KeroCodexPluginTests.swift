//
//  KeroCodexPluginTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Codex takes Terminal's hooks only as a plugin installed from a
/// marketplace. These build the marketplace and stand in for Codex's config
/// and cache inside the temporary directory; running `codex` itself is left
/// to the app.
struct KeroCodexPluginTests {
    private let root: URL
    private let hooks = Data("{\"_\": \"TERMINAL_INTEGRATION_ID=codex\"}\n".utf8)

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("terminal-codex-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The layout Codex reads: an index under `.agents/plugins`, and a
    /// manifest pointing at a separate hook file, since Codex drops hooks
    /// written inline in the manifest when it installs.
    @Test func theMarketplaceHasTheLayoutCodexReads() throws {
        defer { cleanUp() }
        let marketplace = root.appendingPathComponent("marketplace", isDirectory: true)
        try KeroCodexPlugin.writeMarketplace(at: marketplace, hooks: hooks)

        let index = try JSONSerialization.jsonObject(with: Data(contentsOf:
            marketplace.appendingPathComponent(".agents/plugins/marketplace.json"))) as? [String: Any]
        #expect(index?["name"] as? String == KeroCodexPlugin.marketplaceName)
        let entry = (index?["plugins"] as? [[String: Any]])?.first
        #expect((entry?["source"] as? [String: String])?["path"] == "./plugins/terminal-agent-state")

        let plugin = marketplace.appendingPathComponent("plugins/terminal-agent-state")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            plugin.appendingPathComponent(".codex-plugin/plugin.json"))) as? [String: Any]
        #expect(manifest?["hooks"] as? String == "./hooks/hooks.json")
        #expect(manifest?["version"] as? String == KeroCodexPlugin.version)
        #expect(try Data(contentsOf: plugin.appendingPathComponent("hooks/hooks.json")) == hooks)

        // Rewriting is how a new build updates it.
        try KeroCodexPlugin.writeMarketplace(at: marketplace, hooks: hooks)
    }

    /// Current only when Codex lists the plugin and its cached hook file is
    /// this build's; anything else needs `codex plugin add` again.
    @Test func currentMeansEnabledWithThisBuildsHooksCached() throws {
        defer { cleanUp() }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        #expect(!KeroCodexPlugin.isInstalled(codexHome: codexHome))
        #expect(!KeroCodexPlugin.isCurrent(codexHome: codexHome, hooks: hooks))

        try """
        [marketplaces.terminal-agent-integrations]
        source_type = "local"

        [plugins."terminal-agent-state@terminal-agent-integrations"]
        enabled = true
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        #expect(KeroCodexPlugin.isInstalled(codexHome: codexHome))
        #expect(!KeroCodexPlugin.isCurrent(codexHome: codexHome, hooks: hooks))

        let cached = codexHome.appendingPathComponent(
            "plugins/cache/terminal-agent-integrations/terminal-agent-state/\(KeroCodexPlugin.version)/hooks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: cached.appendingPathComponent("hooks.json"))
        #expect(!KeroCodexPlugin.isCurrent(codexHome: codexHome, hooks: hooks))
        try hooks.write(to: cached.appendingPathComponent("hooks.json"))
        #expect(KeroCodexPlugin.isCurrent(codexHome: codexHome, hooks: hooks))
    }

    @Test func codexHomeFollowsTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(KeroCodexPlugin.codexHome(homeURL: home, environment: [:]).path == "/Users/someone/.codex")
        #expect(KeroCodexPlugin.codexHome(homeURL: home, environment: ["CODEX_HOME": "~/alt"]).path
            == "/Users/someone/alt")
        #expect(KeroCodexPlugin.codexHome(homeURL: home, environment: ["CODEX_HOME": "/opt/codex"]).path
            == "/opt/codex")
    }

    /// The first match wins, as in a shell, and relative entries are skipped:
    /// they would resolve against whatever directory the app runs in.
    @Test func theCommandIsFoundOnThePathInOrder() throws {
        defer { cleanUp() }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tool = directory.appendingPathComponent("codex")
            try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let found = KeroCodexPlugin.executable(
            named: "codex", onPath: "relative/bin:\(root.path)/missing:\(first.path):\(second.path)"
        )
        #expect(found?.path == first.appendingPathComponent("codex").path)
        #expect(KeroCodexPlugin.executable(named: "codex", onPath: "relative/bin") == nil)
    }
}
