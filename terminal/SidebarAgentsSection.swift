//
//  SidebarAgentsSection.swift
//  terminal
//

import SwiftUI
import TerminalCore

/// Every running coding agent in the window, one row per pane, at the foot of
/// the project list. The project rows' badges answer "which project needs
/// me"; this answers "which agent", agents first and location second, so a
/// blocked agent in a background tab of another project is one click away.
struct SidebarAgentsSection: View {
    @ObservedObject var manager: TerminalManager
    let fontSize: Double

    @AppStorage("leftSidebarAgentsCollapsed") private var isCollapsed = false
    @State private var rowsHeight: CGFloat = 0

    /// Rows shown before the list scrolls. The projects stay the sidebar's
    /// main content; the roster gets a strip, not the column.
    private static let maxVisibleRows = 6

    var body: some View {
        let roster = manager.agentRoster
        if !roster.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header(count: roster.count)

                if !isCollapsed {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(roster) { entry in
                                row(for: entry)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowsHeight = $0
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: visibleHeight(rowCount: roster.count) + 6)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
    }

    private func header(count: Int) -> some View {
        let title = String(localized: "Agents")
        return Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7 * sidebarFontScale, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text("Agents")
                    .font(.system(size: 9.5 * sidebarFontScale, weight: .medium))

                Spacer(minLength: 0)

                Text("\(count)")
                    .font(.system(size: 9 * sidebarFontScale, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .foregroundStyle(Color.secondary.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }

    /// Location and focus are resolved here rather than inside the row: the
    /// manager re-publishes every project and tab change, so this is where a
    /// renamed project or a moved focus is seen. A row given the same object
    /// references would compare equal and skip its body.
    private func row(for entry: TerminalManager.AgentRosterEntry) -> some View {
        SidebarAgentRow(
            session: entry.session,
            projectName: entry.project.name,
            tabTitle: entry.tab.displayTitle ?? entry.session.title,
            isFocused: entry.session === focusedSession,
            fontSize: fontSize,
            reveal: { manager.focusAgent(entry.session) }
        )
    }

    /// The terminal the user is looking at: the focused pane of the selected
    /// project's tab. Its row carries the selected-row fill, the same cue the
    /// project list gives the selected project.
    private var focusedSession: TerminalSession? {
        guard case .session(let session)? = manager.selectedProject?.focusedContent else { return nil }
        return session
    }

    /// Rows share one font and two lines, so the measured average stands in
    /// for a row's height. Past the cap the strip stops half a row short:
    /// macOS hides scrollers until a scroll starts, and the cut-off row is
    /// what says there is more below.
    private func visibleHeight(rowCount: Int) -> CGFloat {
        guard rowCount > Self.maxVisibleRows else { return rowsHeight }
        return rowsHeight / CGFloat(rowCount) * (CGFloat(Self.maxVisibleRows) - 0.5)
    }

    /// The same ratio `SidebarProjectRow` scales its designed sizes by.
    private var sidebarFontScale: Double {
        fontSize / AppSettings.defaultSidebarFontSize
    }
}

/// One agent: its status badge, name and state, and where it runs. Observes
/// the session so a status change or rename redraws only this row.
private struct SidebarAgentRow: View {
    @ObservedObject var session: TerminalSession
    let projectName: String
    let tabTitle: String
    let isFocused: Bool
    let fontSize: Double
    let reveal: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        // The roster drops a session once its status clears; until the
        // manager republishes, render nothing rather than a stateless row.
        if let phase = session.agentStatus?.phase {
            Group {
                if isRenaming {
                    rowContent(phase: phase)
                } else {
                    Button(action: reveal) {
                        rowContent(phase: phase)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(phase: phase))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFocused ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
            )
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Rename Agent…") {
                    beginRename()
                }
                if session.agentCustomLabel != nil {
                    Button("Use Agent Name") {
                        session.agentCustomLabel = nil
                    }
                }
                Divider()
                Button("Reveal Pane", action: reveal)
            }
        }
    }

    private func rowContent(phase: KeroAgentPhase) -> some View {
        HStack(spacing: 8) {
            // The badge's shape and motion carry the state, so the row never
            // relies on its tint; the row's own label speaks it to VoiceOver.
            AgentStatusBadgeRepresentable(rollup: KeroAgentRollup(phase: phase, count: 1))
                .fixedSize()
                .frame(width: max(14, fontSize), alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: titleFontSize, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) {
                            if !renameFocused, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    HStack(spacing: 6) {
                        Text(verbatim: session.agentDisplayName)
                            .font(.system(size: titleFontSize))
                            .foregroundStyle(isFocused ? .primary : .secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(phase.rosterLabel)
                            .font(.system(size: supportingFontSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(verbatim: "\(projectName) › \(tabTitle)")
                    .font(.system(size: supportingFontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func accessibilityLabel(phase: KeroAgentPhase) -> String {
        String(
            localized: "\(session.agentDisplayName), \(phase.rosterLabel), in project \(projectName), tab \(tabTitle)",
            comment: "Accessibility label for an agent row in the sidebar. Placeholders: agent name, agent state (such as “working”), project name, tab title."
        )
    }

    private func beginRename() {
        renameDraft = session.agentDisplayName
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        session.agentCustomLabel = KeroAgentRoster.normalizedLabel(renameDraft)
        isRenaming = false
    }

    private var supportingFontSize: Double {
        10 * sidebarFontScale
    }

    /// The project row's title size, so an agent's name and a project's
    /// read at the same level of the sidebar's hierarchy.
    private var titleFontSize: Double {
        11.5 * sidebarFontScale
    }

    private var sidebarFontScale: Double {
        fontSize / AppSettings.defaultSidebarFontSize
    }
}
