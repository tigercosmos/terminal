//
//  ProtectedDirectoriesTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// The point of this policy is that the reads never happen, so every test here
/// works on paths alone — building a fixture inside `~/Desktop` to prove
/// Terminal stays out of `~/Desktop` would be the one thing that raises the
/// privacy prompt.
///
/// Serialized because the switch is process-wide: it stands in for a setting,
/// and two tests flipping it at once would each see the other's answer.
@Suite(.serialized)
struct ProtectedDirectoriesTests {
    /// Restores the switch however the test leaves it, so a failure part way
    /// through cannot leave the rest of the suite refusing to read anything.
    private func withAccessDenied(_ body: () -> Void) {
        let previous = ProtectedDirectories.deniesAccess
        ProtectedDirectories.deniesAccess = true
        defer { ProtectedDirectories.deniesAccess = previous }
        body()
    }

    private func home(_ relativePath: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(relativePath)
    }

    @Test func theFoldersMacOSPromptsForAreProtected() {
        for folder in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"] {
            #expect(ProtectedDirectories.isProtected(home(folder)))
        }
        #expect(ProtectedDirectories.isProtected(home("Library/Mobile Documents")))
        #expect(ProtectedDirectories.isProtected("/Volumes"))
    }

    @Test func everythingInsideAProtectedFolderIsProtectedToo() {
        #expect(ProtectedDirectories.isProtected(home("Desktop/notes/todo.md")))
        #expect(ProtectedDirectories.isProtected("/Volumes/Backup/photos"))
    }

    /// Home is the ordinary place for a terminal to open, and listing it is not
    /// what macOS prompts for — so it stays readable even with the switch on.
    @Test func homeItselfAndOrdinaryProjectsAreNot() {
        #expect(!ProtectedDirectories.isProtected(NSHomeDirectory()))
        #expect(!ProtectedDirectories.isProtected(home("Developer/terminal")))
        #expect(!ProtectedDirectories.isProtected("/usr/local"))
        #expect(!ProtectedDirectories.isProtected(""))
    }

    /// A name that merely starts with a protected one is a different folder.
    @Test func aSiblingWithASharedPrefixIsNotProtected() {
        #expect(!ProtectedDirectories.isProtected(home("Desktops")))
        #expect(!ProtectedDirectories.isProtected(home("Downloads-old/file.zip")))
    }

    /// A shell can report any of these, and a path that walked around the
    /// check would be a prompt for the folder the user just excluded.
    @Test func theCheckCannotBeWalkedAroundWithDotsOrSlashes() {
        #expect(ProtectedDirectories.isProtected(home("Desktop/")))
        #expect(ProtectedDirectories.isProtected(home("Desktop//notes")))
        #expect(ProtectedDirectories.isProtected(home("Documents/../Desktop/notes")))
        #expect(ProtectedDirectories.isProtected(home("./Desktop")))
    }

    @Test func nothingIsDeniedWhileTheSettingIsOff() {
        let previous = ProtectedDirectories.deniesAccess
        ProtectedDirectories.deniesAccess = false
        defer { ProtectedDirectories.deniesAccess = previous }
        #expect(!ProtectedDirectories.denies(home("Desktop")))
        #expect(ProtectedDirectories.isProtected(home("Desktop")))
    }

    @Test func theSettingTurnsAProtectedPathIntoARefusal() {
        withAccessDenied {
            #expect(ProtectedDirectories.denies(home("Downloads/installer.dmg")))
            #expect(!ProtectedDirectories.denies(home("Developer/terminal")))
        }
    }

    /// Git is spawned by the app, so macOS bills what it reads to Terminal.
    /// The refusal has to come before the process, not after its output.
    @Test func gitRefusesToRunInAProtectedDirectory() {
        withAccessDenied {
            let result = GitCommand.run(["status"], in: GitDirectory(home("Desktop/repo")))
            #expect(result.status == GitCommand.accessDeniedStatus)
            #expect(result.stdout.isEmpty)
            #expect(!result.stderr.isEmpty)
        }
    }

    @Test func gitStillRunsOutsideProtectedFolders() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        withAccessDenied {
            // `--version` rather than a repository question: those answer with
            // Git's own fatal status, which is the one the refusal borrows.
            let result = GitCommand.run(["--version"], in: GitDirectory(directory.path))
            #expect(result.status == 0)
            #expect(result.stdout.hasPrefix("git version"))
        }
    }

    @Test func theFileTreeSaysWhyItIsEmptyRatherThanLookingEmpty() {
        let model = FileTreeModel(reportFailure: { _, _ in })
        withAccessDenied {
            model.sync(root: home("Desktop"))
            #expect(model.status == .restricted)
            #expect(model.items.isEmpty)
        }
    }

    /// Turning the setting off has to bring the tree back on the next tick —
    /// the panel re-syncs on a timer and never re-roots, so a status left
    /// behind would be permanent.
    @Test func theTreeRecoversWhenTheSettingGoesBackOff() {
        let model = FileTreeModel(reportFailure: { _, _ in })
        let previous = ProtectedDirectories.deniesAccess
        defer { ProtectedDirectories.deniesAccess = previous }

        ProtectedDirectories.deniesAccess = true
        model.sync(root: home("Desktop"))
        #expect(model.status == .restricted)

        // Recovered at home rather than back at `~/Desktop`: with the switch
        // off, a sync there would list the folder — the one read this file
        // must never make.
        ProtectedDirectories.deniesAccess = false
        model.sync(root: NSHomeDirectory())
        #expect(model.status == .ready)
    }

    /// Drawing a locked row must not be the call that touches the folder, so
    /// the tree reports these as directories without asking the file system.
    @Test func aProtectedFolderStillAppearsAsARowInsideHome() {
        let model = FileTreeModel(reportFailure: { _, _ in })
        withAccessDenied {
            model.sync(root: NSHomeDirectory())
            guard let desktop = model.items.first(where: { $0.name == "Desktop" }) else {
                // A machine whose home has no Desktop has nothing to check.
                return
            }
            #expect(desktop.isDirectory)
            #expect(model.isRestricted(desktop))
            model.toggle(desktop)
            #expect(!model.isExpanded(desktop))
        }
    }
}
