//
//  ProtectedDirectories.swift
//  TerminalCore
//

import Foundation

/// The folders macOS keeps behind a privacy prompt, and whether Terminal is
/// allowed to read them on its own account.
///
/// The dialog — "Terminal would like to access files in your Desktop folder" —
/// is raised by the system on the first read, and it names the app whichever
/// part of the app made the call. The panels are what make those calls
/// unbidden: the file tree follows the shell's `cd` and re-reads on a
/// two-second timer, and Git runs wherever the tree is pointed. Walking a
/// terminal into `~/Downloads` is enough to raise a prompt nobody asked for,
/// and to raise it again on the next tick.
///
/// With ``deniesAccess`` set, every read the app makes on its own account asks
/// here first and gives up before the syscall. A call that is never made cannot
/// raise a dialog, so the answer is a refusal rather than a prompt.
///
/// This can only answer for reads Terminal makes. A command the user runs —
/// `ls ~/Desktop` — is the shell's own read: macOS bills it to Terminal, but
/// the app never sees it and has nothing to refuse on its behalf.
public enum ProtectedDirectories {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var isDenying = false

    /// Whether Terminal refuses to read the guarded folders itself. Mirrored
    /// from the user's setting, and read from whichever thread a panel's read
    /// happens to be on — Git runs off the main actor.
    public nonisolated static var deniesAccess: Bool {
        get { lock.withLock { isDenying } }
        set { lock.withLock { isDenying = newValue } }
    }

    /// The folders this refuses, resolved once: home does not move while the
    /// app is running.
    ///
    /// `~/Desktop`, `~/Documents`, and `~/Downloads` are the three macOS
    /// prompts for by name. The media folders and iCloud Drive are here too
    /// because the setting is a blanket refusal — someone who turns it on is
    /// saying Terminal has no business in their personal folders, not asking
    /// for a list that tracks whatever macOS currently happens to guard.
    /// `/Volumes` covers external and network disks, which macOS guards as a
    /// class rather than by name.
    ///
    /// Home itself is not on the list. Listing it is not what macOS prompts
    /// for, and a terminal that opens in the home directory is the ordinary
    /// case — refusing it would empty the file panel for everyone who turned
    /// this on, without a prompt having been at stake.
    private nonisolated static let roots: [String] = {
        let home = NSHomeDirectory() as NSString
        return [
            "Desktop", "Documents", "Downloads",
            "Movies", "Music", "Pictures",
            "Library/Mobile Documents",
        ].map { home.appendingPathComponent($0) } + ["/Volumes"]
    }()

    /// Whether `path` is one of the guarded folders or sits inside one.
    ///
    /// Standardized first, so a trailing slash, a doubled separator, or the
    /// `~/Desktop/../Desktop` a shell can report cannot walk around the check.
    /// Symlinks are deliberately left unresolved: resolving them means asking
    /// the file system about the very path being held at arm's length, and a
    /// symlink into a guarded folder still reads as a path outside one to
    /// every check below — the read it feeds is the caller's own to make.
    public nonisolated static func isProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        // `isDirectory:` is supplied rather than inferred: the inferring
        // initializer stats the path, and this runs on paths that exist only
        // to be avoided.
        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        return roots.contains { standardized == $0 || standardized.hasPrefix($0 + "/") }
    }

    /// Whether a read of `path` has to be refused rather than attempted.
    public nonisolated static func denies(_ path: String) -> Bool {
        deniesAccess && isProtected(path)
    }

    /// What the panels say in place of the contents they didn't read. One
    /// sentence, because it appears where a Git error or an ssh diagnostic
    /// would: the user turned this on, so it needs to name the setting rather
    /// than explain the idea.
    public nonisolated static var refusalMessage: String {
        String(
            localized: "Terminal isn’t allowed to read this folder. Turn off “Never read protected folders” in Settings to browse it.",
            bundle: .module,
            comment: "Shown in the file and Git panels in place of a protected folder's contents."
        )
    }
}
