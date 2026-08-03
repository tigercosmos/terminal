//
//  GitCommandTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// A throwaway repository in a temp directory, so the Git plumbing can be
/// asked real questions instead of mocked ones. Deleted when the test's
/// instance goes.
final class FixtureRepository {
    let url: URL
    var directory: GitDirectory { GitDirectory(url.path) }

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("git-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        // `-c` rather than a config file, so the fixture does not depend on
        // whatever the machine running the tests has set globally.
        run("init", "-q", "-b", "main")
        run("config", "user.email", "fixture@example.test")
        run("config", "user.name", "Fixture")
        run("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func run(_ arguments: String...) -> (status: Int32, stdout: String, stderr: String) {
        GitCommand.run(arguments, in: directory, allowingRepositoryHooks: true)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
    }

    func commit(_ message: String) {
        run("add", "-A")
        run("commit", "-q", "-m", message)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath).path
    }
}

/// Every Git read and every Git action in the app goes through `GitCommand`,
/// which is what lets the untrusted-repository discipline be applied once. That
/// discipline had never been checked against a repository that actually tries
/// to abuse it — and "the hook did not run" is not something a screenshot can
/// show.
struct GitCommandTests {
    // MARK: - Untrusted repository configuration

    /// `core.fsmonitor` runs on any index refresh, including the `status`
    /// Terminal issues the moment a project directory is opened. A downloaded
    /// repository, or one an agent has written `.git/config` in, would
    /// otherwise get code execution with no user action at all.
    @Test func aRepositorysFsmonitorHookNeverRuns() throws {
        let repository = try FixtureRepository()
        let marker = repository.path("fsmonitor-ran")
        try repository.write("touch \(marker)\n", to: "hook.sh")
        repository.run("update-index", "--chmod=+x", "hook.sh")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repository.path("hook.sh")
        )
        repository.run("config", "core.fsmonitor", repository.path("hook.sh"))

        try repository.write("a\n", to: "file.txt")
        let result = GitCommand.run(["status", "--porcelain"], in: repository.directory)
        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// `core.hooksPath` is disabled for the same reason: `status` can write the
    /// index and fire `post-index-change`.
    @Test func aRepositorysHooksNeverRunForAPlainRead() throws {
        let repository = try FixtureRepository()
        let marker = repository.path("hook-ran")
        let hooks = repository.url.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\ntouch \(marker)\n".utf8).write(to: hook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path
        )
        repository.run("config", "core.hooksPath", hooks.path)

        try repository.write("a\n", to: "file.txt")
        GitCommand.run(["add", "-A"], in: repository.directory)
        let result = GitCommand.run(
            ["commit", "-q", "-m", "no hooks"], in: repository.directory
        )
        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// Hooks are a legitimate part of an *explicit* Git action, so the
    /// operation runners turn them back on — which is the other half of the
    /// rule and the half a regression would silently take away.
    @Test func anExplicitActionMayRunTheRepositorysHooks() throws {
        let repository = try FixtureRepository()
        let marker = repository.path("hook-ran")
        let hooks = repository.url.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\ntouch \(marker)\n".utf8).write(to: hook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path
        )
        repository.run("config", "core.hooksPath", hooks.path)

        try repository.write("a\n", to: "file.txt")
        GitCommand.run(
            ["add", "-A"], in: repository.directory, allowingRepositoryHooks: true
        )
        let result = GitCommand.run(
            ["commit", "-q", "-m", "with hooks"], in: repository.directory,
            allowingRepositoryHooks: true
        )
        #expect(result.status == 0)
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    /// The locale is pinned so Git's diagnostics are safe to match on, and a
    /// credential prompt fails rather than hanging invisibly behind the app.
    @Test func gitRunsUnderAPinnedLocaleAndNoTerminalPrompt() throws {
        let repository = try FixtureRepository()
        let environment = GitCommand.run(["var", "-l"], in: repository.directory)
        #expect(environment.status == 0)

        // A push to a URL that would need credentials must come back rather
        // than sit waiting for someone to type a password into nothing.
        let push = GitCommand.run(
            ["ls-remote", "https://127.0.0.1:1/repo.git"], in: repository.directory
        )
        #expect(push.status != 0)
    }

    // MARK: - Running Git

    @Test func outputComesBackDecodedWithItsStatus() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "file.txt")
        repository.commit("first")

        let log = GitCommand.run(["log", "--format=%s"], in: repository.directory)
        #expect(log.status == 0)
        #expect(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "first")
        #expect(log.stderr.isEmpty)
    }

    @Test func aFailedCommandReportsItsStatusAndItsMessage() throws {
        let repository = try FixtureRepository()
        let result = GitCommand.run(["cat-file", "-p", "deadbeef"], in: repository.directory)
        #expect(result.status != 0)
        #expect(!result.stderr.isEmpty)
    }

    /// A directory that is not there at all must come back as a failure rather
    /// than as an empty answer that reads like a clean repository.
    @Test func aMissingDirectoryIsAFailureRatherThanAnEmptyAnswer() {
        let absent = GitDirectory("/nonexistent-\(UUID().uuidString)")
        let result = GitCommand.run(["status", "--porcelain"], in: absent)
        #expect(result.status != 0)
    }

    /// Callers parse NUL-delimited records, where a replacement character would
    /// silently become part of a path — so undecodable output is treated as no
    /// output rather than repaired.
    @Test func undecodableOutputIsDroppedRatherThanRepaired() throws {
        let repository = try FixtureRepository()
        let invalidUTF8 = Data([0x68, 0x69, 0xff, 0xfe, 0x0a])
        try invalidUTF8.write(to: repository.url.appendingPathComponent("bytes.bin"))
        repository.commit("binary")

        let raw = GitCommand.runData(
            ["show", "HEAD:bytes.bin"], in: repository.directory
        )
        #expect(raw.status == 0)
        #expect(raw.stdout == invalidUTF8)

        let decoded = GitCommand.run(["show", "HEAD:bytes.bin"], in: repository.directory)
        #expect(decoded.stdout.isEmpty)
    }

    /// One byte past the ceiling is kept on purpose, so a payload sitting
    /// exactly on it can be told from one that runs over.
    @Test func aCappedReadKeepsOneBytePastTheCeiling() throws {
        let repository = try FixtureRepository()
        try repository.write(String(repeating: "x", count: 5000), to: "big.txt")
        repository.commit("big")

        let capped = GitCommand.runData(
            ["show", "HEAD:big.txt"], in: repository.directory, maxBytes: 100
        )
        #expect(capped.status == 0)
        #expect(capped.stdout.count == 101)

        let exact = GitCommand.runData(
            ["show", "HEAD:big.txt"], in: repository.directory, maxBytes: 5000
        )
        #expect(exact.stdout.count == 5000)
    }

    /// Reading either pipe only after the process exits deadlocks when the
    /// other fills, and a listing this size fills one.
    @Test func aLargeListingDoesNotDeadlock() throws {
        let repository = try FixtureRepository()
        for index in 0..<800 {
            try repository.write("\(index)\n", to: "dir\(index % 20)/file\(index).txt")
        }
        let status = GitCommand.run(
            ["status", "--porcelain", "-z", "--untracked-files=all"],
            in: repository.directory
        )
        #expect(status.status == 0)
        #expect(status.stdout.split(separator: "\0").count == 800)
    }

    @Test func inputIsWrittenToGitsStandardInput() throws {
        let repository = try FixtureRepository()
        let content = Data(String(repeating: "line\n", count: 20_000).utf8)
        let hashed = GitCommand.runData(
            ["hash-object", "-w", "--stdin"], in: repository.directory, input: content
        )
        #expect(hashed.status == 0)

        let object = String(decoding: hashed.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let read = GitCommand.runData(["cat-file", "blob", object], in: repository.directory)
        #expect(read.stdout == content)
    }

    // MARK: - Directories

    @Test func existingNamesReportsOnlyWhatIsThere() throws {
        let repository = try FixtureRepository()
        try repository.write("a\n", to: "MERGE_HEAD")
        let found = GitCommand.existingNames(
            ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"], in: repository.directory
        )
        #expect(found == ["MERGE_HEAD"])
    }

    /// A remote path is shown as `host:/path` so it can never be read as a
    /// local one.
    @Test func aRemoteDirectoryNamesItsHost() {
        let destination = RemoteShellDestination(
            destination: "user@example.test", reachOptions: []
        )
        let remote = GitDirectory("/srv/repo", on: destination)
        #expect(!remote.isLocal)
        #expect(remote.host == "example.test")
        #expect(remote.displayPath == "example.test:/srv/repo")

        let local = GitDirectory("/srv/repo")
        #expect(local.isLocal)
        #expect(local.host == nil)
        #expect(local.displayPath == "/srv/repo")
    }

    /// A host that could not say where its terminal is leaves the panels
    /// wherever an ssh command lands, and the header says the host alone
    /// rather than a path that means nothing.
    @Test func aHostWithNoKnownDirectoryIsShownByNameAlone() {
        let destination = RemoteShellDestination(destination: "example.test", reachOptions: [])
        #expect(GitDirectory(".", on: destination).displayPath == "example.test")
        #expect(GitDirectory("", on: destination).displayPath == "example.test")
    }

    /// A relative path is resolved against the directory and stays on that
    /// machine — it is only ever handed back to Git or to ssh.
    @Test func aRelativePathStaysOnItsOwnMachine() {
        let destination = RemoteShellDestination(destination: "example.test", reachOptions: [])
        let remote = GitDirectory("/srv/repo", on: destination)
        #expect(remote.appending("src/main.swift") == "/srv/repo/src/main.swift")
        #expect(remote.directory("/srv/other").remote == destination)
        #expect(GitDirectory("/a").directory("/b").isLocal)
    }

    // MARK: - Where a panel is pointed

    @Test func aLocalPanelResolvesToItsOwnDirectory() {
        #expect(PanelRoot.local("/srv/repo").directory().path == "/srv/repo")
        #expect(PanelRoot.local("/srv/repo").remote == nil)
        #expect(PanelRoot.local("").isUnset)
        #expect(!PanelRoot.local("/srv").isUnset)
        #expect(!PanelRoot.local("/srv").isRemoteLoginFallback)
    }

    /// A header can show the located path before anything has been asked of
    /// the host; a login-directory fallback has nothing to show yet.
    @Test func aRemotePanelShowsWhatItKnowsBeforeAskingTheHost() {
        let destination = RemoteShellDestination(destination: "example.test", reachOptions: [])
        let located = PanelRoot.remote(.located("/srv/repo"), destination)
        #expect(located.provisionalPath == "/srv/repo")
        #expect(located.remote == destination)
        #expect(!located.isRemoteLoginFallback)
        #expect(located.directory().path == "/srv/repo")

        let fallback = PanelRoot.remote(.loginDirectory, destination)
        #expect(fallback.provisionalPath.isEmpty)
        // The panel says so, because a confidently wrong directory is worse
        // than an admitted unknown one.
        #expect(fallback.isRemoteLoginFallback)
    }

    @Test func onlyALocatedRootHasAPath() {
        #expect(RemoteRoot.located("/srv/repo").locatedPath == "/srv/repo")
        #expect(RemoteRoot.loginDirectory.locatedPath == nil)
    }

    /// A shell's own hostname is rarely spelled the way the user spelled the
    /// destination, but when it matches, the reported directory is believed
    /// without a round trip to the host.
    @Test func aMatchingReportIsBelievedWithoutAskingTheHost() {
        let destination = RemoteShellDestination(
            destination: "build.example.test", reachOptions: []
        )
        let located = RemoteRoot.locate(
            report: (host: "build", path: "/srv/repo"),
            connection: nil,
            on: destination
        )
        #expect(located == .located("/srv/repo"))
    }

    /// With no report and no connection there is nothing to place, so the
    /// panels look wherever an ssh command lands rather than guessing.
    @Test func nothingToGoOnMeansTheLoginDirectory() {
        let destination = RemoteShellDestination(destination: "example.test", reachOptions: [])
        #expect(RemoteRoot.locate(report: nil, connection: nil, on: destination)
            == .loginDirectory)
    }
}
