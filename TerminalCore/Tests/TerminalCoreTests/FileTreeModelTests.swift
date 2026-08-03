//
//  FileTreeModelTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Removes the fixture trees a test made, at the end of that test.
///
/// Not a `deinit` on the tree itself: a test that stops mentioning its tree
/// half way through — most of them do, since the model is what is being
/// driven — would otherwise have the directory deleted out from under the
/// model still reading it.
private final class TemporaryDirectories {
    var urls: [URL] = []
    deinit {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}

/// A throwaway directory tree, so renames, creates, and deletes run against a
/// real file system instead of a mocked one.
private final class FixtureTree {
    let url: URL

    init(_ layout: [String]) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for entry in layout {
            let target = url.appendingPathComponent(entry)
            if entry.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true
                )
            } else {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(entry.utf8).write(to: target)
            }
        }
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath).path
    }
}

/// Renaming, creating, and deleting in the file tree touch the user's real
/// files, and every rejection they make is a message rather than a crash — so
/// "it refused, and said why" is the behavior, and it was previously only
/// observable by driving the sidebar with an alert on screen.
@MainActor
struct FileTreeModelTests {
    /// What the model would have put in an alert. Injected in place of the
    /// `NSAlert` the app supplies; see `FileTreeModel.FailureReporter`.
    private final class Failures {
        var reported: [(message: String, detail: String)] = []
    }

    private let temporary = TemporaryDirectories()

    private func makeTree(
        _ layout: [String]
    ) throws -> (FixtureTree, FileTreeModel, Failures) {
        let tree = try FixtureTree(layout)
        temporary.urls.append(tree.url)
        let failures = Failures()
        let model = FileTreeModel(reportFailure: { message, detail in
            failures.reported.append((message, detail))
        })
        model.sync(root: tree.url.path)
        return (tree, model, failures)
    }

    private func item(_ model: FileTreeModel, _ name: String) throws -> FileTreeModel.Item {
        try #require(
            model.items.first { $0.name == name },
            "no row named \(name) in \(model.items.map(\.name))"
        )
    }

    // MARK: - Rows

    @Test func theTreeListsWhatIsOnDisk() throws {
        let (_, model, _) = try makeTree(["b.txt", "a.txt", "sub/"])
        #expect(model.items.map(\.name).sorted() == ["a.txt", "b.txt", "sub"])
        #expect(try item(model, "sub").isDirectory)
        #expect(try !item(model, "a.txt").isDirectory)
        #expect(model.items.allSatisfy { $0.depth == 0 })
    }

    /// A directory's children appear only once it is expanded — the whole
    /// point of a lazily-expanded tree.
    @Test func expandingADirectoryRevealsItsChildren() throws {
        let (_, model, _) = try makeTree(["sub/inner.txt"])
        #expect(!model.items.contains { $0.name == "inner.txt" })

        model.toggle(try item(model, "sub"))
        #expect(model.isExpanded(try item(model, "sub")))
        let inner = try item(model, "inner.txt")
        #expect(inner.depth == 1)

        model.toggle(try item(model, "sub"))
        #expect(!model.items.contains { $0.name == "inner.txt" })
    }

    // MARK: - Renaming

    @Test func aRenameMovesTheFileAndReportsItsNewPath() throws {
        let (tree, model, failures) = try makeTree(["a.txt"])
        let renamed = model.rename(try item(model, "a.txt"), to: "b.txt")
        #expect(renamed == tree.path("b.txt"))
        #expect(tree.exists("b.txt"))
        #expect(!tree.exists("a.txt"))
        #expect(failures.reported.isEmpty)
        #expect(model.items.map(\.name) == ["b.txt"])
    }

    /// A name is one path component. Anything that would change *which*
    /// directory the file lands in is refused, with a reason.
    @Test func aNameThatWouldChangeDirectoriesIsRefused() throws {
        let (tree, model, failures) = try makeTree(["a.txt"])
        // Named uniquely so the check cannot be confused by anything else that
        // has ever been written beside the fixture.
        let escape = "escaped-\(UUID().uuidString).txt"
        for name in ["../\(escape)", "sub/a.txt", ".", ".."] {
            #expect(model.rename(try item(model, "a.txt"), to: name) == nil)
        }
        #expect(failures.reported.count == 4)
        #expect(failures.reported.allSatisfy { !$0.detail.isEmpty })
        #expect(tree.exists("a.txt"))
        #expect(!tree.exists("../\(escape)"))
    }

    /// Renaming onto a name that is taken would silently replace the other
    /// file, so it is refused instead.
    @Test func aRenameOntoAnExistingNameIsRefused() throws {
        let (tree, model, failures) = try makeTree(["a.txt", "b.txt"])
        #expect(model.rename(try item(model, "a.txt"), to: "b.txt") == nil)
        #expect(failures.reported.count == 1)
        #expect(tree.exists("a.txt"))
        #expect(tree.exists("b.txt"))
    }

    /// On a case-insensitive volume `foo` and `Foo` are the same file, so a
    /// case-only rename must not be read as a collision with itself.
    @Test func aCaseOnlyRenameIsNotACollision() throws {
        let (tree, model, failures) = try makeTree(["notes.txt"])
        #expect(model.rename(try item(model, "notes.txt"), to: "Notes.txt") != nil)
        #expect(failures.reported.isEmpty)
        #expect(tree.exists("Notes.txt"))
    }

    @Test func anEmptyOrUnchangedNameIsNotARenameAtAll() throws {
        let (_, model, failures) = try makeTree(["a.txt"])
        #expect(model.rename(try item(model, "a.txt"), to: "   ") == nil)
        #expect(model.rename(try item(model, "a.txt"), to: "a.txt") == nil)
        // Not an error either — the user simply did not change anything.
        #expect(failures.reported.isEmpty)
    }

    /// Expansion follows a renamed directory, including its expanded children,
    /// so the tree does not collapse under the user.
    @Test func expansionSurvivesADirectoryRename() throws {
        let (tree, model, _) = try makeTree(["sub/deeper/leaf.txt"])
        model.toggle(try item(model, "sub"))
        model.toggle(try item(model, "deeper"))
        #expect(model.items.contains { $0.name == "leaf.txt" })

        #expect(model.rename(try item(model, "sub"), to: "moved") != nil)
        #expect(model.isExpanded(try item(model, "moved")))
        #expect(model.isExpanded(try item(model, "deeper")))
        #expect(model.items.contains { $0.name == "leaf.txt" })
    }

    @Test func aRenameBeginsAndCancelsWithoutTouchingDisk() throws {
        let (tree, model, _) = try makeTree(["a.txt"])
        model.beginRename(try item(model, "a.txt"))
        #expect(model.renamingPath == tree.path("a.txt"))
        model.cancelRename()
        #expect(model.renamingPath == nil)
        #expect(tree.exists("a.txt"))
    }

    // MARK: - Creating

    @Test func aDraftBecomesAFileOnDisk() throws {
        let (tree, model, failures) = try makeTree([])
        model.beginNewFile(in: tree.url.path)
        #expect(model.draft?.isDirectory == false)
        #expect(model.items.contains { $0.isDraft })

        #expect(model.commitDraft(name: "new.txt") == tree.path("new.txt"))
        #expect(tree.exists("new.txt"))
        #expect(model.draft == nil)
        #expect(failures.reported.isEmpty)
    }

    @Test func aFolderDraftBecomesADirectory() throws {
        let (tree, model, _) = try makeTree([])
        model.beginNewFolder(in: tree.url.path)
        #expect(model.draft?.isDirectory == true)
        // A folder is created rather than opened, so nothing is returned.
        _ = model.commitDraft(name: "sub")
        #expect(tree.exists("sub"))
        #expect(try item(model, "sub").isDirectory)
    }

    @Test func aDraftIsRefusedTheSameNamesARenameIs() throws {
        let (tree, model, failures) = try makeTree(["taken.txt"])
        // Committing clears the draft either way, so each refusal needs its
        // own — which is also what the panel does after showing the alert.
        let escape = "escaped-\(UUID().uuidString).txt"
        model.beginNewFile(in: tree.url.path)
        #expect(model.commitDraft(name: "../\(escape)") == nil)
        model.beginNewFile(in: tree.url.path)
        #expect(model.commitDraft(name: "taken.txt") == nil)
        #expect(failures.reported.count == 2)
        #expect(!tree.exists("../\(escape)"))
    }

    @Test func aCancelledDraftLeavesNothingBehind() throws {
        let (tree, model, _) = try makeTree([])
        model.beginNewFile(in: tree.url.path)
        model.cancelDraft()
        #expect(model.draft == nil)
        #expect(!model.items.contains { $0.isDraft })
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.url.path).isEmpty)
    }

    // MARK: - Roots

    @Test func aTreeWithNoRootHasNoRows() throws {
        let (_, model, _) = try makeTree(["a.txt"])
        model.sync(root: "")
        #expect(model.items.isEmpty)
        #expect(model.rootPath.isEmpty)
    }

    /// The rows describe one machine. Pointing the tree at a host must not
    /// leave rows from wherever it was pointed before on screen, since those
    /// are not that host's files.
    @Test func movingToARemoteHostDropsTheLocalRows() throws {
        let (_, model, _) = try makeTree(["a.txt"])
        #expect(!model.items.isEmpty)
        #expect(model.isEditable)

        let destination = RemoteShellDestination(destination: "example.test", reachOptions: [])
        model.sync(remote: destination, directory: nil)
        #expect(model.items.isEmpty)
        #expect(model.remoteHost == "example.test")
        #expect(model.remoteDestination == destination)
        // Renaming and deleting are for this machine only.
        #expect(!model.isEditable)
    }

    /// Editing is refused wholesale on a remote tree rather than per action,
    /// so nothing can reach the file system with a path from another machine.
    @Test func aRemoteTreeRefusesEveryEdit() throws {
        let (tree, model, failures) = try makeTree(["a.txt"])
        let local = try item(model, "a.txt")
        model.sync(
            remote: RemoteShellDestination(destination: "example.test", reachOptions: []),
            directory: "/srv"
        )
        #expect(model.rename(local, to: "b.txt") == nil)
        model.moveToTrash(local)
        #expect(tree.exists("a.txt"))
        #expect(failures.reported.isEmpty)
    }
}
