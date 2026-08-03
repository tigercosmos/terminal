//
//  TerminalFindTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

/// Records what the find bar asked of the backend, so a sequence of user
/// actions can be checked against the calls it should have produced.
private final class StubSurface: TerminalFindSurface {
    enum Call: Equatable {
        case begin(String)
        case end
        case step(forward: Bool)
        case findSelection
    }

    var hasSelection = false
    var calls: [Call] = []

    func beginFind(_ needle: String) { calls.append(.begin(needle)) }
    func endFind() { calls.append(.end) }
    func stepFind(forward: Bool) { calls.append(.step(forward: forward)) }
    func findSelection() { calls.append(.findSelection) }
}

/// The find bar is a state machine fed from two sides at once — the user
/// typing and navigating, and the backend reporting starts, ends, and counts
/// asynchronously. Most of its rules exist because one side raced the other,
/// which is exactly what is hard to reproduce by hand.
@MainActor
struct TerminalFindTests {
    /// Held by the suite, not by a local: `TerminalFind` keeps its surface
    /// `unowned` because the session owns both, and a stub that went out of
    /// scope mid-test would be read after it was gone. Swift Testing builds a
    /// fresh suite instance per test, so each one gets its own pair.
    private let surface = StubSurface()
    private let find: TerminalFind

    init() {
        find = TerminalFind(surface: surface)
    }

    @Test func aFindStartsClosedAndSearchesNothing() {
        #expect(!find.isPresented)
        #expect(find.total == nil)
        #expect(find.selected == nil)
        find.query = "needle"
        // Typing while closed must not start a search behind the user's back.
        #expect(surface.calls.isEmpty)
    }

    /// The needle survives a close, so reopening offers the previous term
    /// again — and the bar takes focus each time so ⌘F re-selects it.
    @Test func openingSearchesTheStandingNeedleAndClaimsFocus() {
        find.query = "needle"
        find.present()
        #expect(find.isPresented)
        #expect(find.focusRequest == 1)
        #expect(surface.calls == [.begin("needle")])

        find.present()
        #expect(find.focusRequest == 2)
    }

    @Test func everyEditRestartsTheSearch() {
        find.present()
        find.query = "a"
        find.query = "ab"
        // The same text again is not an edit.
        find.query = "ab"
        #expect(surface.calls == [.begin(""), .begin("a"), .begin("ab")])
    }

    /// Counts belong to a needle. Showing the previous term's tally next to the
    /// new one is the visible failure this guards.
    @Test func aRestartDropsTheCountsFromThePreviousNeedle() {
        find.present()
        find.update(total: 7)
        find.update(selected: 2)
        find.query = "new"
        #expect(find.total == nil)
        #expect(find.selected == nil)
    }

    @Test func closingClearsTheHighlightsAndTheCounts() {
        find.present()
        find.update(total: 3)
        surface.calls.removeAll()

        find.dismiss()
        #expect(!find.isPresented)
        #expect(find.total == nil)
        #expect(surface.calls == [.end])

        // Closing an already-closed bar must not send a second end at a
        // backend that is no longer searching.
        find.dismiss()
        #expect(surface.calls == [.end])
    }

    // MARK: - Navigation

    @Test func navigationStepsTheBackendInBothDirections() {
        find.present()
        find.query = "a"
        surface.calls.removeAll()
        find.perform(.next)
        find.perform(.previous)
        #expect(surface.calls == [.step(forward: true), .step(forward: false)])
    }

    /// ⌘G with the bar closed resumes the last search rather than doing
    /// nothing, the way Find Next behaves elsewhere on macOS.
    @Test func findNextOnAClosedBarReopensIt() {
        find.query = "a"
        find.perform(.next)
        #expect(find.isPresented)
        #expect(find.focusRequest == 1)
        // Reopening restarts the search; it does not step a find that is not
        // running yet.
        #expect(surface.calls == [.begin("a")])
    }

    @Test func navigationWithNoNeedleDoesNothingAtAll() {
        find.perform(.next)
        #expect(!find.isPresented)
        #expect(surface.calls.isEmpty)
    }

    /// ⌘E resolves the needle backend-side, so the selection never has to be
    /// read out and re-escaped here — and with nothing selected there is
    /// nothing to ask for.
    @Test func useSelectionOnlyAsksWhenSomethingIsSelected() {
        find.perform(.useSelection)
        #expect(surface.calls.isEmpty)

        surface.hasSelection = true
        find.perform(.useSelection)
        #expect(surface.calls == [.findSelection])
    }

    /// Terminal output is read-only, so Find and Replace stays disabled while a
    /// terminal is focused and must do nothing if it arrives anyway.
    @Test func replaceIsIgnoredInATerminal() {
        find.present()
        surface.calls.removeAll()
        find.perform(.replace)
        #expect(surface.calls.isEmpty)
        #expect(find.isPresented)
    }

    // MARK: - Reports from the backend

    /// A backend-initiated find (⌘E) opens the bar and writes the needle it
    /// resolved — without echoing that needle back as a fresh search, which
    /// would restart the one already running.
    @Test func aReportedNeedleIsAdoptedWithoutRestartingTheSearch() {
        find.started(needle: "resolved")
        #expect(find.isPresented)
        #expect(find.query == "resolved")
        #expect(find.focusRequest == 1)
        #expect(surface.calls.isEmpty)
    }

    /// A backend may report a start for a search already under way. Claiming
    /// focus again would re-select the field mid-edit and eat what is being
    /// typed.
    @Test func aStartForAnAlreadyOpenBarDoesNotStealFocus() {
        find.present()
        #expect(find.focusRequest == 1)
        find.started(needle: "resolved")
        #expect(find.focusRequest == 1)
        #expect(find.query == "resolved")
    }

    @Test func anEmptyOrUnchangedReportedNeedleLeavesTheQueryAlone() {
        find.query = "typed"
        find.present()
        find.started(needle: "")
        #expect(find.query == "typed")
        find.started(needle: "typed")
        #expect(find.query == "typed")
    }

    /// When the backend ends the search itself, the bar mirrors it rather than
    /// sending an end straight back at it.
    @Test func aBackendInitiatedEndIsMirroredWithoutTalkingBack() {
        find.present()
        find.update(total: 4)
        surface.calls.removeAll()

        find.ended()
        #expect(!find.isPresented)
        #expect(find.total == nil)
        #expect(surface.calls.isEmpty)
    }

    @Test func reportedCountsAreWhatTheBarShows() {
        find.present()
        find.update(total: 12)
        find.update(selected: 3)
        #expect(find.total == 12)
        #expect(find.selected == 3)
    }

    // MARK: - Revealing the first match

    /// A backend tallies matches but selects none until asked, so the first
    /// non-empty result for a needle jumps to one: typing in the find bar is
    /// meant to reveal the hit, not merely count it.
    @Test func theFirstNonEmptyCountJumpsToAMatch() async {
        find.present()
        find.query = "a"
        surface.calls.removeAll()

        find.update(total: 3)
        await settle()
        #expect(surface.calls == [.step(forward: true)])
    }

    /// A backend reports each restart as a burst of counts, several per
    /// keystroke. Only the first of them reveals; the rest must not keep
    /// stepping the selection forward under the user.
    @Test func laterCountsForTheSameNeedleDoNotStepAgain() async {
        find.present()
        find.query = "a"
        surface.calls.removeAll()

        find.update(total: 3)
        find.update(total: 5)
        find.update(total: 6)
        await settle()
        #expect(surface.calls == [.step(forward: true)])
    }

    @Test func aCountOfZeroOrNoneRevealsNothing() async {
        find.present()
        find.query = "a"
        surface.calls.removeAll()

        find.update(total: 0)
        find.update(total: nil)
        await settle()
        #expect(surface.calls.isEmpty)
    }

    /// The reveal is deferred so it never re-enters the backend from inside its
    /// own callback — which means the needle can have moved on by the time it
    /// runs, and a reveal belonging to the old one must be dropped.
    @Test func aRevealForASupersededNeedleIsDropped() async {
        find.present()
        find.query = "a"
        find.update(total: 3)
        find.query = "ab"
        surface.calls.removeAll()

        await settle()
        #expect(surface.calls.isEmpty)
    }

    @Test func aRevealIsDroppedWhenTheBarClosedFirst() async {
        find.present()
        find.query = "a"
        find.update(total: 3)
        find.dismiss()
        surface.calls.removeAll()

        await settle()
        #expect(surface.calls.isEmpty)
    }

    /// The reveal is dispatched onto the main queue; this lets it run.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
