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
                            Text("+\(hiddenCount) more — open Berthly to see all")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            MenuBarPill(text: "\(runningCount) running", color: .statusRunning)
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

/// Both directions act immediately on click, same as every container/machine row's play/stop
/// button below. The stop button is tinted red (unlike the rows' plain `.secondary` icons) since
/// this one has a much bigger blast radius — it kills every running container on the machine, not
/// just ones Berthly manages — and that difference needs to read at a glance even though the
/// interaction itself is a single click either way.
private struct MenuBarDaemonRow: View {
    let isRunning: Bool
    let isBusy: Bool
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(\.openWindow) private var openWindow

    private var isVersionMismatch: Bool {
        if case .versionMismatch = service.daemonState { return true }
        return false
    }

    var body: some View {
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
                // Neutral, not red — the leading dot now owns the "is it running" status read,
                // so the button is free to read as plain action, matching every other stop
                // button in this panel. The blast-radius warning still lives in the tooltip.
                Button {
                    Task { await service.stopDaemon() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.hoverIcon)
                .help("Stop container daemon — this stops every running container on this Mac, not just ones Berthly manages")
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
                Image(systemName: status.systemImage)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(status.color)
                    .padding(2.5)
                    .background(Circle().fill(.background))
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
                Button {
                    run { try await service.stopContainer(container.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Stop")
            } else {
                Button {
                    run { try await service.startContainer(container.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Start")
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
            } else {
                Button {
                    run { try await service.startMachine(machine.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.hoverIcon)
                .disabled(isWorking)
                .help("Start")
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
/// used for the daemon stop confirmation below, which is proven to work reliably in this exact
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
