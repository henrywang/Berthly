// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// `openWindow(id:)` has no built-in single-instance behavior for a plain `WindowGroup` — calling
/// it when a main window already exists opens a duplicate instead of focusing the existing one.
/// `bridge.isMainWindowOpen` (set by `MainWindowView`'s `.onAppear`/`.onDisappear`) is what lets
/// every menu bar entry point here check before deciding whether to call it.
///
/// Also closes the menu bar popover itself: a native `NSStatusItem` menu always dismisses after
/// any item is chosen, but a `menuBarExtraStyle(.window)` popover doesn't — SwiftUI has no public
/// API to close it, only the built-in "click the status item again" / "click outside" gestures.
/// Every call site of this helper hands off to the main window (opening a sheet or selecting an
/// item), so leaving the popover open after that reads as broken, not intentional. Closes
/// `bridge.menuBarPopoverWindow` directly (captured via `WindowAccessor` below) rather than
/// guessing at a private window class name or a style-mask heuristic that risks closing the wrong
/// window (e.g. a sheet that's mid-presentation).
@MainActor
private func openOrFocusMainWindow(bridge: MenuBarBridge, openWindow: OpenWindowAction) {
    if !bridge.isMainWindowOpen {
        openWindow(id: "main")
    }
    NSApp.activate(ignoringOtherApps: true)
    bridge.menuBarPopoverWindow?.close()
}

/// Captures the hosting `NSWindow` of whatever it's attached to, with no visible footprint —
/// SwiftUI has no direct API for "give me my own window," so this is the standard workaround.
/// Resolves in both `makeNSView` and `updateNSView`: `makeNSView` often runs during an off-window
/// sizing/measurement pass (`view.window` is still nil then), so a single attempt in `makeNSView`
/// alone misses it — `updateNSView` fires on every subsequent SwiftUI update, giving repeated
/// chances to catch the window once the view is actually attached.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Content of the `MenuBarExtra` in `BerthlyApp`. A live-updating monitor: daemon status,
/// running containers/machines with quick actions, and shortcuts into the main window.
struct MenuBarView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            daemonHeader
                .padding(12)

            if service.isConnected {
                Divider()

                // Pinned items show regardless of running/stopped state — the whole point of
                // pinning is quick access that doesn't depend on the item currently being live.
                let pinnedContainers = service.pinnedContainers
                let pinnedMachines = service.pinnedMachines
                // Excluded from the running sections below so a pinned-and-running item doesn't
                // render twice — its one row already lives in the PINNED section.
                let otherRunningContainers = service.runningContainers.filter { !service.pinnedContainerIDs.contains($0.id) }
                let otherRunningMachines = service.runningMachines.filter { !service.pinnedMachineIDs.contains($0.id) }

                if pinnedContainers.isEmpty && pinnedMachines.isEmpty
                    && otherRunningContainers.isEmpty && otherRunningMachines.isEmpty {
                    Text("No running containers or machines.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    // menuBarExtraStyle(.window) sizes the panel to the view's ideal size, and a
                    // ScrollView bounded only by .frame(maxHeight:) reports zero ideal height —
                    // the panel would collapse around it. Cap rows instead of scrolling, which is
                    // also how native menu-bar popovers (Wi-Fi, Bluetooth) handle long lists.
                    let visibleContainers = otherRunningContainers.prefix(5)
                    let visibleMachines = otherRunningMachines.prefix(3)
                    let hiddenCount = (otherRunningContainers.count - visibleContainers.count)
                        + (otherRunningMachines.count - visibleMachines.count)

                    VStack(alignment: .leading, spacing: 10) {
                        // Each row now carries its own type glyph (MenuBarTypeTile, in the icon
                        // tile itself) instead of relying on a section header to say "these are
                        // containers" — so containers and machines can share one header per group
                        // instead of needing a CONTAINERS/MACHINES split under each.
                        //
                        // Not capped like RUNNING below — pins are user-curated and expected to
                        // stay small, so truncating them would defeat the point.
                        if !pinnedContainers.isEmpty || !pinnedMachines.isEmpty {
                            MenuBarSectionHeader("PINNED")
                            ForEach(pinnedContainers) { container in
                                MenuBarContainerRow(container: container)
                            }
                            ForEach(pinnedMachines) { machine in
                                MenuBarMachineRow(machine: machine)
                            }
                        }
                        if !visibleContainers.isEmpty || !visibleMachines.isEmpty {
                            MenuBarSectionHeader("RUNNING")
                            ForEach(Array(visibleContainers)) { container in
                                MenuBarContainerRow(container: container)
                            }
                            ForEach(Array(visibleMachines)) { machine in
                                MenuBarMachineRow(machine: machine)
                            }
                        }
                        if hiddenCount > 0 {
                            // A button, not plain text — it tells the user to open Berthly, so
                            // it should do that itself rather than sending them to the Dock.
                            MenuBarMoreButton(hiddenCount: hiddenCount) {
                                openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            Divider()

            VStack(spacing: 0) {
                MenuBarRunSubmenu(disabled: !service.isConnected) {
                    bridge.pendingIntent = .openRunContainerSheet
                    openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
                } onSelectMachine: {
                    bridge.pendingIntent = .openCreateMachineSheet
                    openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
                }
                MenuBarFooterButton("Open Berthly", systemImage: "macwindow", shortcut: "⌘O",
                                    key: KeyboardShortcut("o", modifiers: .command)) {
                    openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
                }
                // Settings in the popover footer, per menu-bar-app convention — users may live in
                // this panel for days without ever opening the main window.
                MenuBarFooterButton("Settings…", systemImage: "gearshape", shortcut: "⌘,",
                                    key: KeyboardShortcut(",", modifiers: .command)) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    bridge.menuBarPopoverWindow?.close()
                }
                MenuBarFooterButton("Quit Berthly", systemImage: "power", shortcut: "⌘Q",
                                    key: KeyboardShortcut("q", modifiers: .command)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .background(WindowAccessor { bridge.menuBarPopoverWindow = $0 })
    }

    // MARK: - Daemon header

    @ViewBuilder
    private var daemonHeader: some View {
        switch service.daemonState {
        case .connected, .versionMismatch:
            VStack(alignment: .leading, spacing: 10) {
                MenuBarSummaryRow(
                    systemImage: "shippingbox",
                    label: "Containers",
                    runningCount: service.runningContainers.count,
                    errorCount: service.errorContainerCount
                )
                MenuBarSummaryRow(
                    systemImage: "desktopcomputer",
                    label: "Machines",
                    runningCount: service.runningMachines.count,
                    errorCount: service.errorMachineCount
                )
                Divider()
                MenuBarDaemonRow(isRunning: true, isBusy: false)
            }
        case .checking, .connecting:
            MenuBarDaemonRow(isRunning: false, isBusy: true)
        case .stopping:
            MenuBarDaemonRow(isRunning: true, isBusy: true)
        case .installedButStopped:
            MenuBarDaemonRow(isRunning: false, isBusy: false)
        case .notInstalled:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.statusError)
                Text("Container is not installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.statusError)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Header rows

private struct MenuBarSummaryRow: View {
    let systemImage: String
    let label: String
    let runningCount: Int
    let errorCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.callout.weight(.medium))
            Spacer()
            // Neutral at zero so green always means something is actually running — two green
            // "0 running" pills otherwise read as an affirmative signal about nothing.
            MenuBarPill(text: "\(runningCount) running",
                        color: runningCount > 0 ? .statusRunning : .secondary)
            if errorCount > 0 {
                MenuBarPill(text: "\(errorCount) error", color: .statusError)
            }
        }
    }
}

private struct MenuBarPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Stopped → running calls `startDaemon()` directly, no confirm — starting is harmless. Running →
/// stopped expands an inline confirmation first: a real daemon stop kills every running container
/// on this Mac, not just ones Berthly manages, and a tooltip nobody hovers isn't enough guard for
/// that blast radius — a stray click must not be able to do it silently. The button itself stays
/// the same plain `stop.fill` as every row's stop button; the extra danger is communicated by the
/// confirm step, not by tinting the icon.
private struct MenuBarDaemonRow: View {
    let isRunning: Bool
    let isBusy: Bool
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @State private var showStopConfirm = false

    private var isVersionMismatch: Bool {
        if case .versionMismatch = service.daemonState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            // Inline rather than `.alert` — a system alert presented from inside a
            // `menuBarExtraStyle(.window)` panel (a borderless auxiliary NSPanel, not a real
            // window) has been unreliable in practice: the confirmation could disappear without
            // ever running its action. An inline expand/collapse can't have that failure mode.
            // Gated on `isRunning` too so the panel can't linger if the daemon stops out from
            // under it (e.g. stopped from the terminal while the confirm is open).
            if showStopConfirm && isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusError)
                        // `.fixedSize(vertical:)` forces this to wrap to the panel's actual width
                        // instead of reporting its single-line ideal width and getting clipped
                        // with an ellipsis — the default failure mode for Text sized this way
                        // inside a `menuBarExtraStyle(.window)` popover.
                        Text("This stops every running container on this Mac, not just ones Berthly manages — including containers started from the terminal.")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Cancel") { showStopConfirm = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("menuBarStopConfirmCancel")
                        Button("Stop") {
                            showStopConfirm = false
                            Task { await service.stopDaemon() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.statusError)
                        .controlSize(.small)
                        // "Stop" alone collides with every running row's own stop button — an
                        // explicit identifier is the only way to query this one unambiguously.
                        .accessibilityIdentifier("menuBarStopConfirmStop")
                    }
                }
                .padding(10)
                .background(Color.statusError.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.statusError.opacity(0.4), lineWidth: 1)
                )
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Shape-coded, not just color-coded (filled vs outline circle), matching
            // `ContainerStatus.systemImage`'s convention — a colorblind user can still tell
            // running from stopped. Needed because the summary pills above read "0 running" in
            // both states once nothing's running, leaving this the only affirmative "it's up"
            // signal in the row.
            Image(systemName: isRunning ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(isRunning ? Color.statusRunning : .secondary)
            Text("Container Daemon")
                .font(.callout)
            if let version = service.installedContainerVersion {
                Text("v\(version)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if isVersionMismatch {
                Button {
                    openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusError)
                }
                .buttonStyle(.plain)
                .help("Installed container doesn't match the version Berthly requires — open Berthly to update")
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else if isRunning {
                // Toggles the inline confirmation below rather than stopping outright — see the
                // struct doc comment. Toggle (not just show) so a second click backs out.
                Button {
                    showStopConfirm.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.hoverIcon)
                .help("Stop container daemon — this stops every running container on this Mac, not just ones Berthly manages")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("menuBarDaemonStopButton")
            } else {
                Button {
                    Task { await service.startDaemon() }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.hoverIcon)
                .accessibilityIdentifier("menuBarDaemonStartButton")
            }
        }
    }
}

// MARK: - Rows

/// Type glyph (container/machine) tinted in a rounded tile, with the status shape (see
/// `ContainerStatus.systemImage` — deliberately shape-, not just color-, coded so colorblind users
/// can tell states apart) badged on its corner. Replaces a plain leading status icon so a row's
/// kind is identifiable at a glance without needing a CONTAINERS/MACHINES header to say so —
/// needed once PINNED mixes both kinds in one list.
private struct MenuBarTypeTile: View {
    let systemImage: String
    let status: ContainerStatus

    var body: some View {
        // .overlay (not a shared ZStack alignment) so the type glyph defaults to centered and
        // only the badge gets pulled to the corner — a single ZStack(alignment: .bottomTrailing)
        // applies that alignment to every child, including the type icon, which had no frame of
        // its own to center against and so drifted to the corner too.
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.berthlyAccent.opacity(0.15))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.berthlyAccent)
            }
            .overlay(alignment: .bottomTrailing) {
                // Chipped: the badge sits on the accent tile fill and needs the background circle
                // to separate from it. Shared with the sidebar's `TypeStatusGlyph` (unchipped).
                StatusShapeBadge(status: status, size: 7, chipped: true)
                    .offset(x: 4, y: 4)
            }
            .frame(width: 30, height: 30)
    }
}

private struct MenuBarContainerRow: View {
    let container: Container
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 8) {
            MenuBarTypeTile(systemImage: "shippingbox", status: container.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if container.status == .running {
                Button {
                    run { try await service.restartContainer(container.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Restart")
                .accessibilityLabel("Restart")
                Button {
                    run { try await service.stopContainer(container.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button {
                    run { try await service.startContainer(container.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Start")
                .accessibilityLabel("Start")
            }
        }
        .opacity(isWorking ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { openInMainWindow() }
    }

    private func openInMainWindow() {
        bridge.pendingIntent = .selectCompute(.container(container.id))
        openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            try? await action()
            isWorking = false
        }
    }
}

private struct MenuBarMachineRow: View {
    let machine: Machine
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 8) {
            MenuBarTypeTile(systemImage: "desktopcomputer", status: machine.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                Text(machine.resources)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if machine.status == .running {
                Button {
                    run { try await service.stopMachine(machine.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button {
                    run { try await service.startMachine(machine.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Start")
                .accessibilityLabel("Start")
            }
        }
        .opacity(isWorking ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { openInMainWindow() }
    }

    private func openInMainWindow() {
        bridge.pendingIntent = .selectCompute(.machine(machine.id))
        openOrFocusMainWindow(bridge: bridge, openWindow: openWindow)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            try? await action()
            isWorking = false
        }
    }
}

// MARK: - Chrome

private struct MenuBarSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// The "+N more" overflow line under the capped RUNNING section. Hover brightens the text (no
/// background wash — the row is caption-sized and full-width, so the footer buttons' rounded
/// highlight would read as a heavier control than this is) to show it's clickable.
private struct MenuBarMoreButton: View {
    let hiddenCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("+\(hiddenCount) more — open Berthly to see all")
                .font(.caption)
                .foregroundStyle(isHovered ? .primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("menuBarShowAllButton")
    }
}

/// "Run…" as a submenu (Run Container / Create Machine) rather than opening the main window's
/// chooser popover — the user already tells us which one they want here, so there's no need for
/// a second "which kind?" step once the window is open.
///
/// Deliberately custom-built rather than SwiftUI's `Menu`: `Menu` presents its content in a real
/// native `NSMenu`, which renders with system menu chrome regardless of this view's own styling —
/// inside our custom dark popover that reads as a mismatched, jarring native bubble, not part of
/// the app.
///
/// Expands *downward*, in-flow, rather than a sideways flyout like a native submenu: a
/// `menuBarExtraStyle(.window)` popover is a real `NSWindow`/panel sized to fit its content, so
/// anything positioned outside that computed frame (an overlay offset to the side, escaping the
/// popover's bounds like a native submenu would) has nowhere to render — windows clip to their own
/// frame regardless of what SwiftUI's layout system reports. Same expand-in-place approach already
/// used for the daemon stop confirmation above, which is proven to work reliably in this exact
/// panel.
private struct MenuBarRunSubmenu: View {
    let disabled: Bool
    let onSelectContainer: () -> Void
    let onSelectMachine: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Label("Run…", systemImage: "play.fill")
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(isExpanded ? Color.berthlyAccent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    submenuRow("Run Container…") {
                        isExpanded = false
                        onSelectContainer()
                    }
                    submenuRow("Create Machine…") {
                        isExpanded = false
                        onSelectMachine()
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func submenuRow(_ title: String, action: @escaping () -> Void) -> some View {
        SubmenuRow(title: title, action: action)
    }

    private struct SubmenuRow: View {
        let title: String
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isHovered ? Color.berthlyAccent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }
}

private struct MenuBarFooterButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    /// The real key binding matching the displayed `shortcut` hint — active while the popover is
    /// the key window. Without it the hint would be decorative, which reads as broken.
    var key: KeyboardShortcut?
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, systemImage: String, shortcut: String? = nil, key: KeyboardShortcut? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.key = key
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isHovered && !disabled ? Color.berthlyAccent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { isHovered = $0 }
        // The shortcut `Text` sibling gets folded into this button's accessibility label (e.g.
        // "Open Berthly, ⌘O"), which breaks querying by the visible title alone — an explicit
        // identifier decouples that from whatever the label happens to compose to.
        .accessibilityIdentifier(title)
    }
}

// MARK: - Preview

/// The state that motivated the leading status dot on `MenuBarDaemonRow`: with nothing running,
/// both summary pills read "0 running" — ambiguous between "daemon's down" and "daemon's up,
/// idle" — so the dot is the only affirmative "it's up" signal left in the panel.
#Preview("Connected, nothing running") {
    let mock = MockContainerService()
    mock.containers.removeAll()
    mock.machines.removeAll()
    return MenuBarView()
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
}

#Preview {
    let mock = MockContainerService()
    // A running + a stopped item pinned for each kind — the mix that motivated splitting the
    // PINNED section into per-type headers instead of one merged list.
    mock.pinnedContainerIDs = ["3f9a2b7c1d", "d4e5f6a7b8"]
    mock.pinnedMachineIDs = ["dev", "ci-runner"]
    return MenuBarView()
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
}
