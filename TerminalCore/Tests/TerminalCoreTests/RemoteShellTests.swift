//
//  RemoteShellTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Terminal reads the user's own ssh command line out of the kernel and reuses
/// part of it to open a second connection to the same host. Getting that split
/// wrong is not a cosmetic bug: too little and the panels reach a different
/// host than the terminal did, too much and Terminal extends a grant the user
/// never gave it.
struct SSHArgumentParsingTests {
    private func parse(_ commandLine: String) -> RemoteShellDestination? {
        parseSSHArguments(commandLine.split(separator: " ").map(String.init))
    }

    @Test func theFirstOperandIsTheDestination() {
        #expect(parse("ssh example.test")?.destination == "example.test")
        #expect(parse("ssh user@example.test")?.destination == "user@example.test")
        // Anything after the destination is a command for the far side, which
        // is none of Terminal's business.
        #expect(parse("ssh example.test uname -a")?.destination == "example.test")
    }

    @Test func aCommandLineWithNoDestinationIsNotFollowed() {
        #expect(parse("ssh -V") == nil)
        #expect(parse("ssh") == nil)
        // A trailing option whose value never arrived.
        #expect(parse("ssh -p") == nil)
        #expect(parse("ssh --") == nil)
    }

    @Test func aDoubleDashEndsTheOptions() {
        let parsed = parse("ssh -4 -- -weird-host")
        #expect(parsed?.destination == "-weird-host")
        #expect(parsed?.reachOptions == ["-4"])
    }

    /// Options that decide which host is reached, and how it authenticates,
    /// are repeated on Terminal's own connection.
    @Test func theOptionsThatReachTheHostAreKept() {
        #expect(parse("ssh -p 2222 example.test")?.reachOptions == ["-p", "2222"])
        #expect(parse("ssh -i ~/.ssh/id example.test")?.reachOptions == ["-i", "~/.ssh/id"])
        #expect(parse("ssh -J jump example.test")?.reachOptions == ["-J", "jump"])
        #expect(
            parse("ssh -o StrictHostKeyChecking=no example.test")?.reachOptions
                == ["-o", "StrictHostKeyChecking=no"]
        )
        #expect(parse("ssh -4 -C example.test")?.reachOptions == ["-4", "-C"])
    }

    /// Options that shape the interactive session do nothing for a one-shot
    /// command, and `-N` would refuse to run one at all.
    @Test func theOptionsThatShapeTheSessionAreDropped() {
        #expect(parse("ssh -t -N -L 8080:localhost:80 example.test")?.reachOptions == [])
        #expect(parse("ssh -t -N -L 8080:localhost:80 example.test")?.destination
            == "example.test")
    }

    /// Forwarding the agent is a grant to the remote host rather than a way of
    /// reaching it, so Terminal never extends one the user did not ask for on
    /// its own connection.
    @Test func agentForwardingIsNeverRepeated() {
        let parsed = parse("ssh -A -p 22 example.test")
        #expect(parsed?.reachOptions == ["-p", "22"])
    }

    /// A value can be glued to its letter or stand as the next argument, and a
    /// value-taking option inside a cluster consumes the rest of it.
    @Test func aValueIsReadWhetherGluedOrSeparate() {
        #expect(parse("ssh -p2222 example.test")?.reachOptions == ["-p", "2222"])
        #expect(parse("ssh -4p2222 example.test")?.reachOptions == ["-4", "-p", "2222"])
        #expect(parse("ssh -4p 2222 example.test")?.reachOptions == ["-4", "-p", "2222"])
    }

    /// A value-taking option Terminal discards still has to have its value
    /// skipped, or the value would be read as the destination.
    @Test func aDiscardedOptionsValueIsNotMistakenForTheHost() {
        #expect(parse("ssh -L 8080:localhost:80 example.test")?.destination == "example.test")
        #expect(parse("ssh -w 3 example.test")?.destination == "example.test")
    }
}

struct RemoteShellDestinationTests {
    private func destination(_ value: String) -> RemoteShellDestination {
        RemoteShellDestination(destination: value, reachOptions: [])
    }

    /// The header shows a hostname, and only ssh knows what an `ssh_config`
    /// alias resolves to — so this is best-effort by design.
    @Test func theHostIsTheHostnameAlone() {
        #expect(destination("example.test").host == "example.test")
        #expect(destination("user@example.test").host == "example.test")
        #expect(destination("alias").host == "alias")
    }

    /// Only the URI form carries a port or a path; `ssh host:22` is not a
    /// thing, so a colon in a bare destination belongs to an IPv6 literal.
    @Test func aColonIsAPortOnlyInTheURIForm() {
        #expect(destination("ssh://user@example.test:2222/path").host == "example.test")
        #expect(destination("::1").host == "::1")
        // A bracketed IPv6 literal keeps its port: the guard that stops a
        // colon inside `[::1]` from being read as a port separator also stops
        // the real one after it. The header shows a little more than it needs
        // to, which beats showing half an address.
        #expect(destination("ssh://[::1]:2222").host == "[::1]:2222")
    }

    /// A shell reports whatever `hostname` gave it, which is rarely spelled the
    /// way the user spelled the destination — one side may be qualified and the
    /// other not. The first label is the most that can be claimed without
    /// resolving names.
    @Test func aReportedHostIsMatchedOnItsFirstLabel() {
        let host = destination("build.example.test")
        #expect(host.matches(reportedHost: "build"))
        #expect(host.matches(reportedHost: "BUILD.internal"))
        #expect(!host.matches(reportedHost: "other"))
        #expect(!host.matches(reportedHost: ""))
    }

    /// An alias is placed by asking the host what it calls itself. A shell one
    /// ssh further out answers with a third name and is still refused, which is
    /// the case this comparison exists for.
    @Test func anAliasIsPlacedAgainstWhatTheHostConfirms() {
        let alias = destination("prod")
        #expect(alias.namesSameHost(reported: "web-01", confirmed: "web-01.example.test"))
        #expect(!alias.namesSameHost(reported: "db-07", confirmed: "web-01.example.test"))
        #expect(!alias.namesSameHost(reported: "", confirmed: "web-01"))
    }

    /// Read fresh rather than cached, because macOS renames a machine when it
    /// joins a network — but `localhost` is always this one.
    @Test func localhostIsAlwaysThisMachine() {
        #expect(isLocalHostname("localhost"))
        #expect(isLocalHostname("LOCALHOST.local"))
        #expect(isLocalHostname(""))
        #expect(!isLocalHostname("definitely-not-this-machine.example.test"))
    }
}

/// The package carries its own String Catalog, because Xcode extracts
/// `String(localized:)` per target and never reaches into package sources from
/// the app's.
///
/// The hazard that creates is a half-moved entry: code moves into the package,
/// Xcode extracts the key here as new and untranslated, and the translations
/// stay behind in the app's catalog attached to a key nothing uses any more.
/// Nothing about that fails to build, and it ships as English to non-English
/// users only.
struct PackageLocalizationTests {
    private let languages = ["ja", "zh-Hans"]

    /// A key the package uses whose translations are sitting in the app's
    /// catalog has been moved half way. Both sides are read, and the app's is
    /// the one that should be empty.
    @Test func noPackageStringLeftItsTranslationsBehindInTheApp() throws {
        let package = try catalog(at: packageCatalogURL)
        let app = try catalog(at: appCatalogURL)

        for (key, entry) in package where localizations(entry).isEmpty {
            guard let stranded = app[key], !localizations(stranded).isEmpty else { continue }
            Issue.record(
                """
                "\(key)" is used by TerminalCore but its translations are still \
                in terminal/Localizable.xcstrings. Move the entry across.
                """
            )
        }
    }

    /// A key translated into one shipped language and not the other is the
    /// same mistake caught halfway — an entry moved a field at a time.
    @Test func aTranslatedPackageStringIsTranslatedIntoEveryLanguage() throws {
        for (key, entry) in try catalog(at: packageCatalogURL) {
            let present = localizations(entry)
            guard !present.isEmpty else { continue }   // simply not translated yet
            for language in languages {
                #expect(
                    present.contains(language),
                    "\(language) is missing from \"\(key)\", which the others have"
                )
            }
        }
    }

    /// The translations have to reach the built bundle, not only the catalog —
    /// a package that forgets `defaultLocalization` compiles and ships English.
    @Test func theBuiltBundleCarriesEveryLanguage() {
        for language in languages {
            #expect(
                Bundle.module.path(forResource: language, ofType: "lproj") != nil,
                "the package bundle has no \(language) resources"
            )
        }
    }

    /// Guards the tests above from passing vacuously if a catalog stops being
    /// found or stops being read.
    @Test func bothCatalogsAreFoundAndNotEmpty() throws {
        #expect(try catalog(at: packageCatalogURL).count > 1)
        #expect(try catalog(at: appCatalogURL).count > 1)
    }

    /// The languages a key has a real translation in. A `stringUnit` with no
    /// value, or an entry that only records a comment, is not one.
    private func localizations(_ entry: [String: Any]) -> Set<String> {
        guard let all = entry["localizations"] as? [String: Any] else { return [] }
        return Set(all.compactMap { language, value in
            guard let value = value as? [String: Any] else { return nil }
            if let unit = value["stringUnit"] as? [String: Any] {
                return (unit["value"] as? String)?.isEmpty == false ? language : nil
            }
            return value["variations"] != nil ? language : nil
        })
    }

    /// Catalogs are read from the source tree — the built bundle carries only
    /// the compiled `.strings` they become, and the app's is not in it at all.
    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()      // TerminalCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // TerminalCore
            .deletingLastPathComponent()      // the repository
    }

    private var packageCatalogURL: URL {
        repositoryRoot.appending(
            path: "TerminalCore/Sources/TerminalCore/Resources/Localizable.xcstrings"
        )
    }

    private var appCatalogURL: URL {
        repositoryRoot.appending(path: "terminal/Localizable.xcstrings")
    }

    private func catalog(at url: URL) throws -> [String: [String: Any]] {
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require((parsed as? [String: Any])?["strings"] as? [String: [String: Any]])
    }
}
