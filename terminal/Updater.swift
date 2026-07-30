//
//  Updater.swift
//  terminal
//

import Combine
import Sparkle
import SwiftUI

/// App-wide Sparkle updater. A single instance owns the update lifecycle; the
/// "Check for Updates…" menu item and the Settings toggle both drive it.
///
/// The feed URL and the public EdDSA key are read from Info.plist, injected via
/// the `INFOPLIST_KEY_SUFeedURL` and `INFOPLIST_KEY_SUPublicEDKey` build
/// settings. See RELEASING.md for generating the signing keys and publishing
/// updates.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Gates the menu item: Sparkle can't start a check while one is already in
    /// flight, so the command disables itself until it's ready again.
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks for updates on its own schedule. Sparkle owns the
    /// persisted value (in `UserDefaults`); this mirror lets Settings bind to
    /// it and writes changes straight back through.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Whether `SUFeedURL` and `SUPublicEDKey` both carry real values. Set them
    /// in Info.plist — and generate your own signing key pair — before the
    /// in-app updater can do anything; see RELEASING.md.
    static var isUpdateFeedConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    private init() {
        // Don't run the updater in debug builds. Starting it schedules a
        // background check and pops Sparkle's "check for updates
        // automatically?" permission prompt, which is just noise while
        // developing. Release builds start it and behave normally.
        #if DEBUG
        let startImmediately = false
        #else
        // Sparkle can only be started once the feed and public key are real.
        // This fork ships them empty (see Info.plist): starting the updater
        // against an unconfigured feed would either error on every launch or,
        // worse if a URL were guessed, reach a host nobody here controls.
        let startImmediately = Self.isUpdateFeedConfigured
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Seed from Sparkle's persisted value; didSet doesn't fire here.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // Force a silent check on launch when auto-checks are on. Starting the
        // updater only arms Sparkle's *scheduled* checker, which fires once its
        // interval (~a day) has elapsed since the last check — so a normal
        // relaunch checks nothing. Sparkle requires this forced check to run
        // immediately after the updater starts (calling it later interferes
        // with its scheduler), which is why it lives here and is gated on the
        // updater actually having been started.
        if startImmediately && automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Runs Sparkle's user-facing update check (progress window and prompts).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The "Check for Updates…" application-menu command.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
