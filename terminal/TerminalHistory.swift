//
//  TerminalHistory.swift
//  terminal
//

import Darwin
import Foundation
import TerminalCore

/// Captures and normalizes styled terminal history without reaching into a
/// terminal backend's buffer representation. A backend writes its screen to a
/// temporary VT file; the rest of this utility operates only on that stream.
enum TerminalHistorySerializer {
    enum CaptureResult {
        case captured(String?)
        case failed
    }

    /// Captures the screen and scrollback a backend exports, keeping at most
    /// the last `maxLines` rows.
    @MainActor
    static func capture(
        from surface: any TerminalBackendSurface, maxLines: Int
    ) -> CaptureResult {
        guard maxLines > 0,
              let captureFile = TerminalCaptureFile.validated(
                  for: surface.exportScreenFile()
              )
        else { return .failed }
        defer { captureFile.remove() }

        guard let capturedVT = try? String(contentsOf: captureFile.fileURL, encoding: .utf8) else {
            return .failed
        }
        return .captured(TerminalHistoryText.normalized(
            from: capturedVT, maxLines: maxLines, isDivider: isRestoredBanner
        ))
    }

    /// Plain visible rows for the Ctrl-Tab thumbnail. This uses the backend's
    /// screen export instead of AppKit bitmap caching because a framebuffer-
    /// only Metal layer cannot be captured reliably. Only the tail of a large
    /// export is read, keeping interactive tab switching bounded even when a
    /// session has megabytes of scrollback.
    @MainActor
    static func previewText(
        from surface: any TerminalBackendSurface,
        maxLines: Int,
        maxColumns: Int
    ) -> String? {
        guard maxLines > 0, maxColumns > 0,
              let captureFile = TerminalCaptureFile.validated(
                  for: surface.exportScreenFile()
              )
        else { return nil }
        defer { captureFile.remove() }

        guard let handle = try? FileHandle(forReadingFrom: captureFile.fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        // Enough for many full terminal viewports, while staying cheap if the
        // exported file contains Terminal's full scrollback allowance.
        let byteLimit: UInt64 = 128 * 1024
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > byteLimit ? end - byteLimit : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.read(upToCount: Int(end - start)),
              !data.isEmpty
        else { return nil }

        return TerminalHistoryText.preview(
            from: String(decoding: data, as: UTF8.self),
            maxLines: maxLines,
            maxColumns: maxColumns,
            startedMidStream: start > 0
        )
    }

    /// A positive-only probe for a primary-buffer scrollback snapshot. A
    /// backend does not export scrollback while an alternate buffer is active,
    /// but an empty primary buffer also produces no file, so false is
    /// inconclusive.
    @MainActor
    static func hasPrimaryScrollback(_ surface: any TerminalBackendSurface) -> Bool {
        guard let captureFile = TerminalCaptureFile.validated(
            for: surface.exportScrollbackFile()
        ) else { return false }
        captureFile.remove()
        return true
    }

    /// Label shown in the restored-history divider.
    private static let restoredBannerSourceLabel = "Session Contents Restored"
    static let restoredBannerLabel = String(
        localized: "Session Contents Restored",
        comment: "Divider between restored terminal scrollback and a new live shell."
    )

    /// The rule that brackets the label on each side of the divider.
    /// `nonisolated` alongside `restoredBannerText(label:)`, which reads it
    /// from a static initializer running outside any actor.
    private nonisolated static let restoredBannerRule = String(repeating: "\u{2500}", count: 4)

    /// The divider's plain, unstyled text — `<rule> <label> <rule>`. `visibleText`
    /// yields exactly this for a divider row, so recognizing one is an equality
    /// check against it.
    /// `nonisolated` because `restoredBannerTexts` builds its set in a static
    /// initializer, which runs outside any actor. The function only formats a
    /// string, so there is nothing for the main actor to protect.
    private nonisolated static func restoredBannerText(label: String) -> String {
        "\(restoredBannerRule) \(label) \(restoredBannerRule)"
    }

    /// A saved capture may have been written under a different app language.
    /// Recognize every bundled translation so changing languages never replays
    /// an old divider as terminal output.
    private static let restoredBannerTexts: Set<String> = {
        var labels = Set([restoredBannerSourceLabel, restoredBannerLabel])
        for localization in Bundle.main.localizations {
            guard let path = Bundle.main.path(
                forResource: localization,
                ofType: "lproj"
            ), let bundle = Bundle(path: path) else { continue }
            labels.insert(
                bundle.localizedString(
                    forKey: restoredBannerSourceLabel,
                    value: restoredBannerSourceLabel,
                    table: "Localizable"
                )
            )
        }
        return Set(labels.map(restoredBannerText))
    }()

    /// A single-line divider fed into the terminal directly beneath replayed
    /// scrollback, marking where the restored output ends and the live shell
    /// begins. Rendered with default colors so it tracks the light/dark theme:
    /// a fixed run of dim rule characters brackets the normal-weight label.
    ///
    /// The rule is a fixed width rather than one spanning the terminal on
    /// purpose. The column count is not reliably known when the banner is built
    /// — the view has not been laid out at its final size yet — so a full-width
    /// rule sized to the wrong count wraps onto a second line. A short rule
    /// always fits and reads the same at any width.
    static func restoredBanner() -> String {
        let dim = "\u{1b}[2m"
        let normal = "\u{1b}[22m"
        return dim + restoredBannerRule + " " + normal
            + restoredBannerLabel + dim + " " + restoredBannerRule
            + TerminalHistoryText.reset
    }

    /// Whether a captured row is a divider a previous restore already wrote.
    /// Replaying one would stack a second divider above every relaunch.
    private static func isRestoredBanner(_ line: String) -> Bool {
        restoredBannerTexts.contains(
            TerminalHistoryText.visibleText(in: line)
                .trimmingCharacters(in: .whitespaces)
        )
    }
}

/// Persists per-session terminal history to a sidecar file, keyed by an opaque
/// string that the session layout snapshot (in `UserDefaults`) references. Kept
/// out of the snapshot itself so `UserDefaults` never holds large blobs.
///
/// Each save rewrites the whole file from the live set of sessions, so keys
/// belonging to sessions that no longer exist are pruned automatically.
enum TerminalHistoryStore {
    /// Debug builds keep their state under `terminal-dev`, matching `AppSettings`
    /// and the separate `com.github.tigercosmos.terminal.dev` bundle id, so a dev build never clobbers
    /// an installed production build's history.
    private static let fileURL: URL = {
        #if DEBUG
        let directory = "terminal-dev"
        #else
        let directory = "terminal"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("terminal-history.json")
    }()

    static func save(_ histories: [String: String]) {
        // Nothing to persist: remove the file so a later restore finds nothing
        // rather than replaying stale output.
        guard !histories.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(histories) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // Saved scrollback is whatever was on screen — keys, tokens, and
            // paths included. The copy staged in the temp directory is already
            // 0600 (`TerminalSession.makeLaunchArtifacts`); this is the same
            // content living for much longer, so it gets the same treatment
            // rather than the umask's.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            NSLog("terminal: failed to write \(fileURL.path): \(error)")
        }
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let histories = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return histories
    }
}
