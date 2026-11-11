//
//  KeroCodexPlugin.swift
//  TerminalCore
//

import Foundation

/// Codex's lifecycle integration: a plugin carrying Terminal's hooks, served
/// from a local marketplace Terminal keeps in its own support folder.
///
/// It cannot be a link like the other integrations. Codex loads plugin hooks
/// only from its own cache, which `codex plugin add` fills by copying the
/// plugin, and it reads a plugin's `hooks` from a separate file rather than
/// from the manifest. So Terminal writes the marketplace, then asks the
/// user's own `codex` to install from it; Codex owns its config format and
/// cache layout, and Terminal never writes either.
///
/// Codex also runs no plugin hook the user has not approved, and approves a
/// plugin's contents as a whole. The first Codex session after installing
/// asks for that review; the hook file must therefore stay byte-identical
/// across Terminal updates, or every user is asked again.
public nonisolated enum KeroCodexPlugin {
    public static let marketplaceName = "terminal-agent-integrations"
    public static let pluginName = "terminal-agent-state"
    /// Part of Codex's cache path. Bump it only together with the hook file.
    public static let version = "1.0.0"
    public static var pluginID: String { "\(pluginName)@\(marketplaceName)" }

    static let marker = "TERMINAL_INTEGRATION_ID=codex"

    public static func codexHome(homeURL: URL, environment: [String: String]) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            if configured == "~" { return homeURL }
            if configured.hasPrefix("~/") {
                return homeURL.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
            }
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The bundled hook file, verified to be Terminal's.
    public static func bundledHooks(bundle: Bundle = .main) throws -> Data {
        for directory in ["AgentIntegrations/codex", "codex", nil] as [String?] {
            guard let url = bundle.url(
                forResource: "terminal-agent-state.codex", withExtension: "json",
                subdirectory: directory
            ), let data = try? Data(contentsOf: url),
                String(decoding: data, as: UTF8.self).contains(marker)
            else { continue }
            return data
        }
        throw KeroAgentIntegrations.IntegrationError.message(
            "Terminal's bundled Codex lifecycle integration is missing."
        )
    }

    /// Writes the marketplace Codex installs from: its index, the plugin's
    /// manifest, and the hook file. Rewritten whole each time, so it always
    /// matches this build; the folder is Terminal's own.
    public static func writeMarketplace(at root: URL, hooks: Data) throws {
        let files = FileManager.default
        let plugin = root.appendingPathComponent("plugins/\(pluginName)", isDirectory: true)
        try files.createDirectory(
            at: root.appendingPathComponent(".agents/plugins", isDirectory: true),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: plugin.appendingPathComponent(".codex-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: plugin.appendingPathComponent("hooks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let marketplace: [String: Any] = [
            "name": marketplaceName,
            "plugins": [[
                "name": pluginName,
                "source": ["source": "local", "path": "./plugins/\(pluginName)"],
                "description": description,
            ]],
        ]
        let manifest: [String: Any] = [
            "name": pluginName,
            "version": version,
            "description": description,
            "hooks": "./hooks/hooks.json",
        ]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        try JSONSerialization.data(withJSONObject: marketplace, options: options)
            .write(to: root.appendingPathComponent(".agents/plugins/marketplace.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: manifest, options: options)
            .write(to: plugin.appendingPathComponent(".codex-plugin/plugin.json"), options: .atomic)
        try hooks.write(to: plugin.appendingPathComponent("hooks/hooks.json"), options: .atomic)
    }

    private static let description = "Managed by Terminal. Reports whether this Codex session is working, waiting for you, or done, and which subagents it runs, to Terminal's agent badges and sidebar. Turning off \"Let coding agents coordinate panes\" removes it."

    /// Whether Codex has this build's hooks installed: the plugin is enabled
    /// in its config and its cached hook file matches the bundled one. A
    /// check of Codex's files rather than a run of `codex`, so launch can
    /// skip the install when nothing changed.
    public static func isCurrent(codexHome: URL, hooks: Data) -> Bool {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              text.contains("[plugins.\"\(pluginID)\"]")
        else { return false }
        let cached = codexHome.appendingPathComponent(
            "plugins/cache/\(marketplaceName)/\(pluginName)/\(version)/hooks/hooks.json"
        )
        return (try? Data(contentsOf: cached)) == hooks
    }

    /// Whether Codex lists the plugin at all, current or not.
    public static func isInstalled(codexHome: URL) -> Bool {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains("[plugins.\"\(pluginID)\"]")
            || text.contains("[marketplaces.\(marketplaceName)]")
    }

    /// `codex` arguments, in order. Each is safe to repeat.
    public static func installArguments(marketplace: URL) -> [[String]] {
        [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "add", pluginID],
        ]
    }

    public static let uninstallArguments: [[String]] = [
        ["plugin", "remove", pluginID],
        ["plugin", "marketplace", "remove", marketplaceName],
    ]

    /// The first executable named `name` on `path`, the way a shell finds it.
    public static func executable(named name: String, onPath path: String) -> URL? {
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
