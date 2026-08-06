//
//  SessionStore.swift
//  TerminalCore
//

import Foundation

/// Panels available in the right sidebar. Raw values are stable names
/// persisted in `SessionSnapshot`.
public enum RightPanel: String, Codable {
    case files
    case git
    case info
    case compare
}

/// Scroll offset and cursor position of a file tab's editor, kept on the
/// `FileTab` so it survives tab switches, and in the session snapshot so it
/// survives relaunches. Every field is optional so decoding tolerates
/// snapshots written by earlier editor stacks.
public struct EditorState: Codable, Equatable {
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var scrollX: Double?
    public var scrollY: Double?

    public init(
        selectionLocation: Int? = nil, selectionLength: Int? = nil,
        scrollX: Double? = nil, scrollY: Double? = nil
    ) {
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.scrollX = scrollX
        self.scrollY = scrollY
    }
}

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory — with their previous scrollback
/// replayed above the prompt when the "Restore session history" setting is on
/// (see `historyKey` and `TerminalHistoryStore`); file and diff panes reload
/// from disk.
public struct SessionSnapshot: Codable {
    public struct ProjectSnapshot: Codable {
        /// A single pane's content — the terminal, file, browser, diff, or
        /// comparison it holds. The original case shapes stay unchanged, so old
        /// saved tabs still decode; see `TabSnapshot`.
        public enum PaneContentSnapshot: Codable {
            case session(workingDirectory: String)
            /// `remoteHost` is set when the path was on a host a terminal had
            /// connected to. Without it a restored tab would open whatever
            /// sits at that path on this machine and look like the same file.
            /// Optional so snapshots written before this feature still decode.
            case file(path: String, editorState: EditorState?, remoteHost: String? = nil)
            case browser(url: String?)
            /// `remoteHost` is set when the repository was on a host a
            /// terminal had connected to, for the same reason a file tab
            /// records one. Optional so snapshots written before this feature
            /// still decode.
            case diff(
                repoRoot: String, path: String, staged: Bool, untracked: Bool,
                origPath: String?, remoteHost: String? = nil
            )
            /// One file as it changed in a historical commit. Its own case
            /// because the stage flags above cannot say which commit, and a
            /// commit diff restored without one would come back as a diff of
            /// the working tree instead.
            case commitDiff(
                repoRoot: String, path: String, origPath: String?,
                commitHash: String, parentHash: String?, shortHash: String,
                remoteHost: String? = nil
            )
            /// The target commit is saved rather than the branch it came from:
            /// a comparison tab is pinned to one commit for its lifetime, so
            /// restoring it must reopen the same comparison, not whatever the
            /// branch has moved on to since.
            case compare(
                repoRoot: String, path: String, origPath: String?,
                targetOID: String, targetName: String, remoteHost: String? = nil
            )
        }

        public struct PaneSnapshot: Codable {
            public var content: PaneContentSnapshot
            public var weight: Double
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, browsers, diffs, comparisons, or when history
            /// restore is off.
            /// Optional so snapshots written before this feature still decode.
            public var historyKey: String?

            public init(
                content: PaneContentSnapshot, weight: Double,
                historyKey: String? = nil
            ) {
                self.content = content
                self.weight = weight
                self.historyKey = historyKey
            }
        }

        public struct ColumnSnapshot: Codable {
            public var panes: [PaneSnapshot]
            public var weight: Double
        }

        /// The persisted recursive pane tree. Fractions belong to individual
        /// splits, so a child can be divided on either axis without affecting
        /// its siblings.
        public indirect enum LayoutSnapshot: Codable {
            case pane(PaneSnapshot)
            case split(
                axis: PaneSplitAxis,
                fraction: Double,
                first: LayoutSnapshot,
                second: LayoutSnapshot
            )
        }

        /// One tab's recursive layout plus the focused leaf's tree-order
        /// position. Decodes both the former column/row format and the original
        /// pre-split single-content format.
        public struct TabSnapshot: Codable {
            public var layout: LayoutSnapshot
            public var focusedPaneIndex: Int
            /// User-assigned tab name; nil when the title is automatic.
            /// Optional so older snapshots still decode.
            public var customName: String?

            public init(
                layout: LayoutSnapshot, focusedPaneIndex: Int,
                customName: String? = nil
            ) {
                self.layout = layout
                self.focusedPaneIndex = focusedPaneIndex
                self.customName = customName
            }

            enum CodingKeys: String, CodingKey {
                case layout, focusedPaneIndex, customName
                case columns, focusedColumn, focusedRow
            }

            public init(from decoder: any Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   container.contains(.layout) {
                    layout = try container.decode(LayoutSnapshot.self, forKey: .layout)
                    focusedPaneIndex =
                        (try? container.decode(Int.self, forKey: .focusedPaneIndex)) ?? 0
                    customName = try? container.decode(String.self, forKey: .customName)
                    return
                }
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   let columns = try? container.decode(
                       [ColumnSnapshot].self, forKey: .columns
                   ), !columns.isEmpty {
                    let nonEmptyColumns = columns.filter { !$0.panes.isEmpty }
                    guard !nonEmptyColumns.isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .columns,
                            in: container,
                            debugDescription: "A pane layout must contain at least one pane"
                        )
                    }
                    let focusedColumn =
                        (try? container.decode(Int.self, forKey: .focusedColumn)) ?? 0
                    let focusedRow =
                        (try? container.decode(Int.self, forKey: .focusedRow)) ?? 0
                    layout = Self.layout(from: nonEmptyColumns)
                    let clampedColumn = min(max(0, focusedColumn), columns.count - 1)
                    focusedPaneIndex = columns[..<clampedColumn]
                        .reduce(0) { $0 + $1.panes.count }
                        + min(
                            max(0, focusedRow),
                            max(0, columns[clampedColumn].panes.count - 1)
                        )
                    customName = try? container.decode(String.self, forKey: .customName)
                    return
                }
                // Legacy: the tab was a single content enum. Wrap it in a
                // one-pane layout.
                let content = try PaneContentSnapshot(from: decoder)
                layout = .pane(PaneSnapshot(content: content, weight: 1))
                focusedPaneIndex = 0
                customName = nil
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(layout, forKey: .layout)
                try container.encode(focusedPaneIndex, forKey: .focusedPaneIndex)
                try container.encodeIfPresent(customName, forKey: .customName)
            }

            /// Converts the former row-of-columns layout to an equivalent
            /// recursive tree so existing saved sessions continue to restore.
            private static func layout(from columns: [ColumnSnapshot]) -> LayoutSnapshot {
                let columnLayouts = columns.map { column in
                    (
                        node: stack(
                            column.panes.map { (.pane($0), $0.weight) },
                            axis: .vertical
                        ),
                        weight: column.weight
                    )
                }
                return stack(
                    columnLayouts.map { ($0.node, $0.weight) },
                    axis: .horizontal
                )
            }

            /// Builds a binary tree that preserves an n-item weighted stack.
            private static func stack(
                _ nodes: [(LayoutSnapshot, Double)], axis: PaneSplitAxis
            ) -> LayoutSnapshot {
                precondition(!nodes.isEmpty)
                guard nodes.count > 1 else { return nodes[0].0 }
                let firstWeight = max(0, nodes[0].1)
                let remainingWeight = nodes.dropFirst().reduce(0) {
                    $0 + max(0, $1.1)
                }
                let total = firstWeight + remainingWeight
                let fraction = total > 0
                    ? firstWeight / total
                    : 1 / Double(nodes.count)
                return .split(
                    axis: axis,
                    fraction: fraction,
                    first: nodes[0].0,
                    second: stack(Array(nodes.dropFirst()), axis: axis)
                )
            }
        }

        public var customName: String?
        /// User-pinned project directory; nil when the directory is
        /// automatic (the closest git repository, never persisted).
        /// Optional so older snapshots still decode.
        public var customDirectory: String?
        public var tabs: [TabSnapshot]
        public var selectedTabIndex: Int?

        public init(
            customName: String? = nil, customDirectory: String? = nil,
            tabs: [TabSnapshot], selectedTabIndex: Int? = nil
        ) {
            self.customName = customName
            self.customDirectory = customDirectory
            self.tabs = tabs
            self.selectedTabIndex = selectedTabIndex
        }
    }

    public var projects: [ProjectSnapshot]
    public var selectedProjectIndex: Int?
    /// Sidebar layout. Optional so snapshots written before these were
    /// captured still decode; nil leaves the window at its defaults.
    public var isLeftSidebarVisible: Bool?
    public var isRightPanelVisible: Bool?
    public var rightPanelTab: RightPanel?

    public init(
        projects: [ProjectSnapshot], selectedProjectIndex: Int? = nil,
        isLeftSidebarVisible: Bool? = nil, isRightPanelVisible: Bool? = nil,
        rightPanelTab: RightPanel? = nil
    ) {
        self.projects = projects
        self.selectedProjectIndex = selectedProjectIndex
        self.isLeftSidebarVisible = isLeftSidebarVisible
        self.isRightPanelVisible = isRightPanelVisible
        self.rightPanelTab = rightPanelTab
    }
}

/// Persisted top level: one `SessionSnapshot` per open window, in
/// window-creation order.
private struct AppSnapshot: Codable {
    var windows: [SessionSnapshot]
}

public enum SessionStore {
    private static let key = "sessionSnapshot"

    public static func save(_ windows: [SessionSnapshot]) {
        guard let data = try? JSONEncoder().encode(AppSnapshot(windows: windows)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func load() -> [SessionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let app = try? JSONDecoder().decode(AppSnapshot.self, from: data) {
            return app.windows
        }
        // Pre-multi-window format: the snapshot of a single window.
        if let single = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return [single]
        }
        return []
    }
}
