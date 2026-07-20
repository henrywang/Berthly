// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ServiceManagement
import SwiftUI

/// Berthly's macOS Settings scene (⌘,): General (launch at login, menu bar icon) and
/// Terminal (theme) tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 400)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    /// Read by `BerthlyApp`'s `MenuBarExtra(isInserted:)` — flipping this inserts/removes the
    /// status item live.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    /// Seeded from the real registration status so the toggle never lies after the user changed
    /// it in System Settings > General > Login Items behind our back.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?
    @Environment(UpdaterService.self) private var updater
    /// Read by `LiveContainerService.poll()` to gate the automatic registry-digest check —
    /// manual checks (Images toolbar) and the recreate action itself are never gated by this.
    @AppStorage("checkImagesForUpdates") private var checkImagesForUpdates = true
    /// Hosts remembered as insecure by the "Allow insecure registry" toggle on Pull/Push/Run/
    /// Sign-in/Machine Create (`ImageStaleness.registryHost`/`rememberInsecureHost`). A one-time
    /// snapshot, not `@AppStorage` (no native `[String]` support) — doesn't live-update if
    /// another window adds one while Settings is open, same limitation `launchAtLogin`'s
    /// snapshot already accepts.
    @State private var insecureHosts = UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? []

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            } footer: {
                Text("With the menu bar icon shown, Berthly keeps monitoring containers while the main window is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("You can always check manually from the Berthly menu: Check for Updates…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check images for updates", isOn: $checkImagesForUpdates)
            } header: {
                Text("Image Updates")
            } footer: {
                Text("""
                Periodically compares your pulled images against their registries and badges \
                the ones with a newer version. You can always check manually from the Images page.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !insecureHosts.isEmpty {
                Section {
                    ForEach(insecureHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.callout.monospaced())
                            Spacer()
                            Button("Remove") { removeInsecureHost(host) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Insecure Registries")
                } footer: {
                    Text("""
                    Hosts you've told Berthly to trust over HTTP instead of HTTPS. Remove one to \
                    require HTTPS again — you'll be asked to allow it again the next time it's needed.
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Couldn't Change Login Item", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func removeInsecureHost(_ host: String) {
        insecureHosts.removeAll { $0 == host }
        UserDefaults.standard.set(insecureHosts, forKey: ImageStaleness.insecureHostsDefaultsKey)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
            // Snap the toggle back to what the system actually has.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Terminal

private struct TerminalSettingsTab: View {
    @AppStorage("terminalTheme") private var themeRaw = TerminalTheme.dracula.rawValue

    private var selectedTheme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dracula }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(TerminalTheme.allCases) { theme in
                        ThemeRow(theme: theme, isSelected: theme == selectedTheme) {
                            themeRaw = theme.rawValue
                        }
                    }
                }
            } header: {
                Text("Terminal Theme")
            }
        }
        .padding(20)
    }
}

/// Shows the theme's own ANSI swatches (not a generic accent color) so the choice is
/// legible before committing — a collapsed `Picker(.menu)` would hide exactly that.
private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(Array(theme.colors.ansi.prefix(8).enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: hex))
                            .frame(width: 14, height: 14)
                    }
                }
                Text(theme.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.berthlyAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.berthlyAccent.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView()
        .environment(UpdaterService(startingUpdater: false))
}
