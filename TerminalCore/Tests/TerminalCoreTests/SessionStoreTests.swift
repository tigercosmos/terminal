//
//  SessionStoreTests.swift
//  TerminalCore
//

import Foundation
import Testing

@testable import TerminalCore

private typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
private typealias LayoutSnapshot = ProjectSnapshot.LayoutSnapshot
private typealias PaneSnapshot = ProjectSnapshot.PaneSnapshot
private typealias ContentSnapshot = ProjectSnapshot.PaneContentSnapshot

/// A saved session outlives the build that wrote it, so every older shape has
/// to keep decoding: a snapshot that throws is a user's whole window layout
/// silently replaced by an empty one. These tests are the only thing that can
/// catch that before a release does.
struct SessionSnapshotDecodingTests {
    // MARK: - Round trip

    @Test func aSplitLayoutSurvivesEncodingAndDecoding() throws {
        let layout = LayoutSnapshot.split(
            axis: .horizontal,
            fraction: 0.25,
            first: .pane(PaneSnapshot(
                content: .session(workingDirectory: "/a"), weight: 1
            )),
            second: .split(
                axis: .vertical,
                fraction: 0.5,
                first: .pane(PaneSnapshot(
                    content: .session(workingDirectory: "/b"), weight: 1,
                    historyKey: "key-b"
                )),
                second: .pane(PaneSnapshot(
                    content: .file(path: "/c", editorState: nil), weight: 1
                ))
            )
        )
        let tab = ProjectSnapshot.TabSnapshot(
            layout: layout, focusedPaneIndex: 2, customName: "Build"
        )
        let decoded = try roundTrip(tab)
        #expect(describe(decoded.layout) == describe(layout))
        #expect(decoded.focusedPaneIndex == 2)
        #expect(decoded.customName == "Build")
        #expect(historyKeys(decoded.layout) == ["key-b"])
    }

    @Test func aWholeWindowSurvivesEncodingAndDecoding() throws {
        let snapshot = SessionSnapshot(
            projects: [
                ProjectSnapshot(
                    customName: "web",
                    customDirectory: "/src/web",
                    tabs: [ProjectSnapshot.TabSnapshot(
                        layout: .pane(PaneSnapshot(
                            content: .browser(url: "https://example.test"), weight: 1
                        )),
                        focusedPaneIndex: 0
                    )],
                    selectedTabIndex: 0
                )
            ],
            selectedProjectIndex: 0,
            isLeftSidebarVisible: false,
            isRightPanelVisible: true,
            rightPanelTab: .compare
        )
        let decoded = try roundTrip(snapshot)
        #expect(decoded.projects.count == 1)
        #expect(decoded.projects[0].customName == "web")
        #expect(decoded.projects[0].customDirectory == "/src/web")
        #expect(decoded.selectedProjectIndex == 0)
        #expect(decoded.isLeftSidebarVisible == false)
        #expect(decoded.isRightPanelVisible == true)
        #expect(decoded.rightPanelTab == .compare)
    }

    /// The sidebar flags are optional so a snapshot written before they were
    /// captured leaves the window at its defaults instead of failing to decode.
    @Test func aSnapshotWithoutTheSidebarFlagsStillDecodes() throws {
        let json = """
            {"projects":[],"selectedProjectIndex":null}
            """
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: Data(json.utf8)
        )
        #expect(decoded.projects.isEmpty)
        #expect(decoded.isLeftSidebarVisible == nil)
        #expect(decoded.isRightPanelVisible == nil)
        #expect(decoded.rightPanelTab == nil)
    }

    /// `remoteHost` was added after these cases existed. Without a default, a
    /// tab saved before it would stop decoding — and take its whole window
    /// with it.
    @Test func contentCasesWrittenBeforeRemoteHostStillDecode() throws {
        let file = try JSONDecoder().decode(
            ContentSnapshot.self,
            from: Data(#"{"file":{"path":"/a","editorState":null}}"#.utf8)
        )
        guard case .file(let path, _, let remoteHost) = file else {
            Issue.record("expected a file case")
            return
        }
        #expect(path == "/a")
        #expect(remoteHost == nil)

        let diff = try JSONDecoder().decode(
            ContentSnapshot.self,
            from: Data(#"""
                {"diff":{"repoRoot":"/r","path":"a.txt","staged":true,
                "untracked":false,"origPath":null}}
                """#.utf8)
        )
        guard case .diff(let repoRoot, _, let staged, _, _, let diffHost) = diff else {
            Issue.record("expected a diff case")
            return
        }
        #expect(repoRoot == "/r")
        #expect(staged)
        #expect(diffHost == nil)
    }

    /// The editor's caret and scroll are all optional for the same reason —
    /// an older snapshot simply reopens the file at the top.
    @Test func anEditorStateWithNothingSetStillDecodes() throws {
        let state = try JSONDecoder().decode(EditorState.self, from: Data("{}".utf8))
        #expect(state == EditorState())
        #expect(state.selectionLocation == nil)
    }

    // MARK: - The former column/row format

    /// Tabs were once a row of weighted columns. Those snapshots have to come
    /// back as the equivalent tree, with the same panes in the same visual
    /// order and the same one focused.
    @Test func theFormerColumnFormatBecomesAnEquivalentTree() throws {
        let json = try legacyColumnsJSON(
            columns: [(paths: ["/a", "/b"], weight: 1), (paths: ["/c"], weight: 3)],
            focusedColumn: 1,
            focusedRow: 0
        )
        let tab = try JSONDecoder().decode(
            ProjectSnapshot.TabSnapshot.self, from: Data(json.utf8)
        )
        // Columns are laid out left to right, panes within one top to bottom;
        // the first column's weight of 1 against the second's 3 is a quarter.
        #expect(
            describe(tab.layout)
                == "split(horizontal,0.25,split(vertical,0.5,pane(/a),pane(/b)),pane(/c))"
        )
        // Tree order is /a, /b, /c — the second column's only pane is index 2.
        #expect(tab.focusedPaneIndex == 2)
        #expect(tab.customName == nil)
    }

    @Test func aFocusOutsideTheFormerGridIsClampedIntoIt() throws {
        let json = try legacyColumnsJSON(
            columns: [(paths: ["/a", "/b"], weight: 1), (paths: ["/c"], weight: 1)],
            focusedColumn: 99,
            focusedRow: 99
        )
        let tab = try JSONDecoder().decode(
            ProjectSnapshot.TabSnapshot.self, from: Data(json.utf8)
        )
        #expect(tab.focusedPaneIndex == 2)
    }

    /// Weightless columns divide evenly rather than collapsing to zero width.
    @Test func formerColumnsWithNoWeightDivideEvenly() throws {
        let json = try legacyColumnsJSON(
            columns: [(paths: ["/a"], weight: 0), (paths: ["/b"], weight: 0)],
            focusedColumn: 0,
            focusedRow: 0
        )
        let tab = try JSONDecoder().decode(
            ProjectSnapshot.TabSnapshot.self, from: Data(json.utf8)
        )
        #expect(describe(tab.layout) == "split(horizontal,0.5,pane(/a),pane(/b))")
    }

    /// A tab was originally a single content enum, with no wrapper at all.
    @Test func theOriginalSingleContentFormatBecomesAOnePaneTab() throws {
        let json = String(
            decoding: try JSONEncoder().encode(
                ContentSnapshot.session(workingDirectory: "/only")
            ),
            as: UTF8.self
        )
        let tab = try JSONDecoder().decode(
            ProjectSnapshot.TabSnapshot.self, from: Data(json.utf8)
        )
        #expect(describe(tab.layout) == "pane(/only)")
        #expect(tab.focusedPaneIndex == 0)
    }

    /// A layout has to hold at least one pane. A column list that holds none is
    /// rejected rather than decoded into a tab with nothing in it.
    @Test func aColumnListWithNoPanesIsRejected() throws {
        let json = #"{"columns":[{"panes":[],"weight":1}],"focusedColumn":0}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ProjectSnapshot.TabSnapshot.self, from: Data(json.utf8)
            )
        }
    }

    // MARK: - Helpers

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }

    /// A stable spelling of a layout tree, since the snapshot types are not
    /// `Equatable` and a failure should say which branch is wrong.
    private func describe(_ layout: LayoutSnapshot) -> String {
        switch layout {
        case .pane(let pane):
            if case .session(let directory) = pane.content { return "pane(\(directory))" }
            if case .file(let path, _, _) = pane.content { return "pane(\(path))" }
            return "pane(?)"
        case .split(let axis, let fraction, let first, let second):
            return "split(\(axis.rawValue),\(fraction),\(describe(first)),\(describe(second)))"
        }
    }

    private func historyKeys(_ layout: LayoutSnapshot) -> [String] {
        switch layout {
        case .pane(let pane):
            return pane.historyKey.map { [$0] } ?? []
        case .split(_, _, let first, let second):
            return historyKeys(first) + historyKeys(second)
        }
    }

    /// Builds a snapshot in the former format. The pane contents are encoded by
    /// the real encoder so the fixture cannot drift from the enum's shape; only
    /// the wrapper, which no longer exists in code, is written by hand.
    private func legacyColumnsJSON(
        columns: [(paths: [String], weight: Double)],
        focusedColumn: Int,
        focusedRow: Int
    ) throws -> String {
        let encoder = JSONEncoder()
        let encoded = try columns.map { column in
            let panes = try column.paths.map { path in
                let content = String(
                    decoding: try encoder.encode(
                        ContentSnapshot.session(workingDirectory: path)
                    ),
                    as: UTF8.self
                )
                return "{\"content\":\(content),\"weight\":1}"
            }
            return "{\"panes\":[\(panes.joined(separator: ","))],"
                + "\"weight\":\(column.weight)}"
        }
        return "{\"columns\":[\(encoded.joined(separator: ","))],"
            + "\"focusedColumn\":\(focusedColumn),\"focusedRow\":\(focusedRow)}"
    }
}

/// `SessionStore` itself owns one `UserDefaults` key, and the format stored
/// under it changed once already. Serialized so the two tests cannot race on
/// that key.
@Suite(.serialized)
struct SessionStoreTests {
    private let key = "sessionSnapshot"

    private func snapshot(named name: String) -> SessionSnapshot {
        SessionSnapshot(
            projects: [ProjectSnapshot(
                customName: name,
                tabs: [ProjectSnapshot.TabSnapshot(
                    layout: .pane(PaneSnapshot(
                        content: .session(workingDirectory: "/tmp"), weight: 1
                    )),
                    focusedPaneIndex: 0
                )],
                selectedTabIndex: 0
            )],
            selectedProjectIndex: 0
        )
    }

    @Test func everyWindowIsSavedAndRestoredInOrder() {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        SessionStore.save([snapshot(named: "first"), snapshot(named: "second")])
        let loaded = SessionStore.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.projects[0].customName) == ["first", "second"])
    }

    /// Terminal saved a single window's snapshot before it had more than one.
    /// Reading one of those has to restore that window rather than none.
    @Test func aSnapshotFromBeforeMultipleWindowsLoadsAsOneWindow() throws {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let data = try JSONEncoder().encode(snapshot(named: "only"))
        UserDefaults.standard.set(data, forKey: key)
        let loaded = SessionStore.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].projects[0].customName == "only")
    }

    @Test func nothingSavedAndUnreadableDataBothRestoreNothing() {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(SessionStore.load().isEmpty)

        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        #expect(SessionStore.load().isEmpty)
    }
}
