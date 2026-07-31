//
//  terminalApp.swift
//  terminal
//

import SwiftUI

struct terminalApp: App {
    @NSApplicationDelegateAdaptor(TerminalApplicationDelegate.self)
    private var applicationDelegate

    // Held here so Sparkle starts at launch and background checks run even if
    // the menu is never opened.
    @StateObject private var updater = Updater.shared

    init() {
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
        _ = Self.zoomInAliasMonitor
    }

    /// Makes plain ⌘= zoom in, alongside the ⌘+ the View menu advertises.
    ///
    /// ⌘+ is ⌘⇧= on a US layout, and an `NSMenuItem` matches one chord only,
    /// so the unshifted key — the one browsers and editors have trained people
    /// to press — would otherwise do nothing. SwiftUI has no hidden alternate
    /// menu item, and a second visible "Zoom In" row is worse than a monitor.
    /// Layouts that type "+" with no Shift reach the menu item directly and
    /// never need this, which is also why the match is on the character rather
    /// than on the US key code. Lazily initialized rather than installed from
    /// `init`, so re-creating the App value cannot stack a second monitor and
    /// make one keypress zoom twice; it then lives for the life of the app.
    private static let zoomInAliasMonitor: Any? =
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Command and no other chord key: ⌃⌘= is Equalize Panes, and ⌘⇧=
            // is the menu item's own equivalent, so both pass through
            // untouched. Caps Lock and the function/keypad bits ride along on
            // ordinary key presses and are deliberately not part of the test.
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            let character = event.charactersIgnoringModifiers
            guard event.window != nil,
                  flags.contains(.command),
                  flags.isDisjoint(with: [.control, .option, .shift]),
                  // The keypad's own + is unshifted everywhere, so it belongs
                  // to the alias rather than to the menu item's ⌘+.
                  character == "=" || (flags.contains(.numericPad) && character == "+")
            else { return event }
            // AppKit runs local monitors synchronously on the main thread.
            MainActor.assumeIsolated {
                ZoomCommand.zoomIn(TerminalManager.keyWindowManager)
            }
            return nil
        }

    var body: some Scene {
        WindowGroup("terminal", id: "main") {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            TerminalCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
private struct WindowRootView: View {
    @StateObject private var manager = TerminalManager()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneObject(manager)
            .onAppear {
                TerminalManager.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// Where a zoom keystroke lands. A focused browser pane zooms its page, the
/// way every browser behaves; anything else moves the app-wide terminal font
/// size, which terminals, editors, and diffs all draw from.
///
/// `manager` is the focused window's when SwiftUI supplied one, and the key
/// window's otherwise, so the menu items and the ⌘= monitor always agree.
@MainActor
enum ZoomCommand {
    static func zoomIn(_ manager: TerminalManager?) {
        if let browser = manager?.selectedBrowser {
            browser.zoomIn()
        } else {
            AppSettings.shared.adjustFontSize(by: 1)
        }
    }

    static func zoomOut(_ manager: TerminalManager?) {
        if let browser = manager?.selectedBrowser {
            browser.zoomOut()
        } else {
            AppSettings.shared.adjustFontSize(by: -1)
        }
    }

    static func actualSize(_ manager: TerminalManager?) {
        if let browser = manager?.selectedBrowser {
            browser.resetZoom()
        } else {
            AppSettings.shared.resetFontSize()
        }
    }
}

/// Menu commands routed to the focused window's manager.
private struct TerminalCommands: Commands {
    @FocusedObject private var manager: TerminalManager?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = TerminalManager.registerWindowOpener {
            openWindow(id: "main")
        }

        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                manager?.newProject()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(manager == nil)

            Button("New Session") {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager == nil)

            Button("New Browser Tab") {
                manager?.newBrowserTab()
            }
            .disabled(manager == nil)

            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Close Pane") {
                // Cmd-W is app-wide: close a pane only when a main window with
                // an open project is key. Otherwise close the key window
                // itself — a non-main window (e.g. Settings), or a main window
                // showing the empty "No open projects" state with no tab left.
                if let manager, manager.selectedProject != nil,
                   NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager == nil)
        }

        CommandGroup(after: .pasteboard) {
            // SwiftUI's Edit menu ships no Find submenu, so Terminal owns these
            // outright. They act on the focused pane — Ghostty's search in a
            // terminal, STTextView's find bar in a file editor — rather than on
            // the first responder, which keeps them live while the find bar's
            // text field has keyboard focus. ⇧⌘G is already Toggle Git Panel,
            // so Find Previous is reachable by ⇧↩ in the bar instead.
            Menu("Find") {
                Button("Find…") {
                    manager?.performFindAction(.show)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button("Find and Replace…") {
                    manager?.performFindAction(.replace)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(manager?.canReplace != true)

                Button("Find Next") {
                    manager?.performFindAction(.next)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button("Find Previous") {
                    manager?.performFindAction(.previous)
                }
                .disabled(manager?.canFind != true)

                Button("Use Selection for Find") {
                    manager?.performFindAction(.useSelection)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(manager?.canFind != true)
            }

            Divider()

            Button("Clear Terminal") {
                manager?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(manager?.canClearActiveTerminal != true)
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                manager?.toggleCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button("Toggle Left Sidebar") {
                manager?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(manager == nil)

            Button("Toggle Right Sidebar") {
                manager?.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Files Panel") {
                manager?.togglePanel(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Git Panel") {
                manager?.togglePanel(.git)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Compare Panel") {
                manager?.togglePanel(.compare)
            }
            // ⇧⌘D would be the obvious "diff" key, but it is already Split
            // Down; ⇧⌘C keeps this with the other panel toggles and does not
            // collide with the terminal's own ⌘C copy.
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Info Panel") {
                manager?.togglePanel(.info)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Divider()

            // Outside a browser pane, zoom moves the one app-wide font size
            // that the Settings slider owns, so every terminal changes
            // together and the size survives a relaunch. Never disabled: with
            // no window in focus there is still a font size to change.
            Button("Zoom In") {
                ZoomCommand.zoomIn(manager)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out") {
                ZoomCommand.zoomOut(manager)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") {
                ZoomCommand.actualSize(manager)
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Projects") {
            Button("Next Project") {
                manager?.selectNextProject()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Previous Project") {
                manager?.selectPreviousProject()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()), id: \.element.id) { index, project in
                Button(project.name) {
                    manager?.selectProject(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandMenu("Browser") {
            Button("Focus Address Bar") {
                manager?.focusBrowserAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button("Reload Page") {
                manager?.reloadSelectedBrowser()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button("Stop Loading") {
                manager?.stopSelectedBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)

            Divider()

            Button("Open in Default Browser") {
                manager?.openSelectedPageInDefaultBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)
        }

        CommandMenu("Tabs") {
            Button("Split Right") {
                manager?.splitRight()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(manager?.canSplit != true)

            Button("Split Down") {
                manager?.splitDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(manager?.canSplit != true)

            Button("Split Left") {
                manager?.splitLeft()
            }
            .disabled(manager?.canSplit != true)

            Button("Split Up") {
                manager?.splitUp()
            }
            .disabled(manager?.canSplit != true)

            Divider()

            Button("Focus Pane Left") {
                manager?.focusPaneLeft()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Right") {
                manager?.focusPaneRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Up") {
                manager?.focusPaneUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Down") {
                manager?.focusPaneDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Previous Pane") {
                manager?.focusPreviousPane()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(manager == nil)

            Button("Focus Next Pane") {
                manager?.focusNextPane()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button("Toggle Pane Zoom") {
                manager?.togglePaneZoom()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(manager?.hasSplitPanes != true)

            Button("Equalize Panes") {
                manager?.equalizePanes()
            }
            .keyboardShortcut("=", modifiers: [.command, .control])
            .disabled(manager?.hasSplitPanes != true)

            Menu("Resize Pane") {
                Button("Up") {
                    manager?.resizePaneUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button("Down") {
                    manager?.resizePaneDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button("Left") {
                    manager?.resizePaneLeft()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button("Right") {
                    manager?.resizePaneRight()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)
            }

            Divider()

            Button("Next Tab") {
                manager?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button("Previous Tab") {
                manager?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, tab in
                Button(tab.displayTitle ?? String(localized: "Tab \(index + 1)")) {
                    manager?.selectTab(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }
}
