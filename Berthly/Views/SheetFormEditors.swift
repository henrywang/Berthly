// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Key/value row editor (build args, labels, env vars)

struct KeyValuePair: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

struct KeyValueEditor: View {
    let title: LocalizedStringKey
    let keyPlaceholder: String
    let valuePlaceholder: String
    /// Stable accessibility-identifier prefix for UI/E2E tests, e.g. "runEnv" yields
    /// "runEnvKeyField"/"runEnvValueField"/"runEnvAddButton". Applied to leaf controls only —
    /// an identifier on a container would override every child's own id. Rows share ids, so
    /// tests that add multiple rows must scope queries; E2E journeys add one row per editor.
    var identifierPrefix: String? = nil
    @Binding var pairs: [KeyValuePair]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach($pairs) { $pair in
                    HStack(spacing: 8) {
                        TextField(keyPlaceholder, text: $pair.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityIdentifier(identifierPrefix.map { "\($0)KeyField" } ?? "")
                        Text("=").foregroundStyle(.tertiary)
                        TextField(valuePlaceholder, text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityIdentifier(identifierPrefix.map { "\($0)ValueField" } ?? "")
                        Button {
                            pairs.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove")
                    }
                }
                Button {
                    pairs.append(KeyValuePair())
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifierPrefix.map { "\($0)AddButton" } ?? "")
            }
        }
    }
}

// MARK: - Free-text list editor (secrets, tmpfs paths, volumes)

struct StringEntry: Identifiable {
    let id = UUID()
    var value: String = ""
}

struct StringListEditor: View {
    let title: LocalizedStringKey
    let placeholder: String
    var helpText: String? = nil
    /// Test-identifier prefix (see KeyValueEditor): "runVolume" → "runVolumeField"/"runVolumeAddButton".
    var identifierPrefix: String? = nil
    @Binding var entries: [StringEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField(placeholder, text: $entry.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .accessibilityIdentifier(identifierPrefix.map { "\($0)Field" } ?? "")
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove")
                    }
                }
                Button {
                    entries.append(StringEntry())
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifierPrefix.map { "\($0)AddButton" } ?? "")
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Network list editor (--network) — select-only rows, no free text

struct NetworkListEditor: View {
    let title: LocalizedStringKey
    var helpText: String? = nil
    let availableNetworks: [Network]
    /// Test-identifier prefix (see KeyValueEditor): "runNetwork" → "runNetworkPicker"/"runNetworkAddButton".
    var identifierPrefix: String? = nil
    @Binding var entries: [StringEntry]

    /// New rows start on the standard network rather than blank, since that's what an empty
    /// `--network` list already resolves to — a fresh row shouldn't look unset.
    private var defaultNetworkName: String? {
        (availableNetworks.first(where: \.isDefault) ?? availableNetworks.first)?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        Picker("", selection: $entry.value) {
                            ForEach(availableNetworks) { network in
                                Text(network.isDefault ? "\(network.name) (default)" : network.name)
                                    .tag(network.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(identifierPrefix.map { "\($0)Picker" } ?? "")
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove")
                    }
                }
                Button {
                    entries.append(StringEntry(value: defaultNetworkName ?? ""))
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(availableNetworks.isEmpty)
                .accessibilityIdentifier(identifierPrefix.map { "\($0)AddButton" } ?? "")
            }
            if let helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Port mapping row editor

enum PortProtocolChoice: String, CaseIterable {
    case tcp, udp
}

struct PortEntry: Identifiable {
    let id = UUID()
    var hostPort: String = ""
    var containerPort: String = ""
    var proto: PortProtocolChoice = .tcp
}

struct PortRowsEditor: View {
    let title: LocalizedStringKey
    /// Test-identifier prefix (see KeyValueEditor): "runPort" → "runPortHostField"/"runPortContainerField"/"runPortAddButton".
    var identifierPrefix: String? = nil
    @Binding var entries: [PortEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("host", text: $entry.hostPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 70)
                            .accessibilityIdentifier(identifierPrefix.map { "\($0)HostField" } ?? "")
                        Text(":").foregroundStyle(.tertiary)
                        TextField("container", text: $entry.containerPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 70)
                            .accessibilityIdentifier(identifierPrefix.map { "\($0)ContainerField" } ?? "")
                        Picker("", selection: $entry.proto) {
                            ForEach(PortProtocolChoice.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Protocol")
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove")
                        Spacer()
                    }
                }
                Button {
                    entries.append(PortEntry())
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifierPrefix.map { "\($0)AddButton" } ?? "")
            }
        }
    }
}

// MARK: - Mount row editor (--mount)

enum MountType: String, CaseIterable {
    case bind, volume, tmpfs
}

struct MountEntry: Identifiable {
    let id = UUID()
    var type: MountType = .bind
    var source: String = ""
    var target: String = ""
    var readOnly: Bool = false
}

struct MountRowsEditor: View {
    let title: LocalizedStringKey
    @Binding var entries: [MountEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        Picker("", selection: $entry.type) {
                            ForEach(MountType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Mount type")
                        if entry.type != .tmpfs {
                            TextField("source", text: $entry.source)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                            .accessibilityHidden(true)
                        TextField("target path", text: $entry.target)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Toggle("RO", isOn: $entry.readOnly)
                            .toggleStyle(.checkbox)
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove")
                    }
                }
                Button {
                    entries.append(MountEntry())
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared platform picker (Build / Pull / Run sheets)

enum SheetPlatformChoice: String, CaseIterable {
    case `default` = ""
    case arm64 = "linux/arm64"
    case amd64 = "linux/amd64"

    var label: String {
        switch self {
        case .default: return "Default (host)"
        case .arm64:   return "linux/arm64"
        case .amd64:   return "linux/amd64"
        }
    }
}

struct PlatformPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: SheetPlatformChoice

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(SheetPlatformChoice.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

// MARK: - Local-image reference field

/// A "local/myapp:1.0" text field with a trailing chevron menu of local images as one-click
/// suggestions, so the user doesn't have to retype a reference that's already pulled or built.
/// Shared by MachineCreateSheet and RunContainerSheet, which both start a compute item from an
/// image reference.
struct LocalImageReferenceField: View {
    @Binding var reference: String
    let images: [ContainerImage]
    /// Test identifier for the inner TextField (on the leaf, not this container — a container
    /// id would override the field's). Distinct per host sheet: "runImageField" vs machine's.
    var fieldIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            TextField("local/myapp:1.0", text: $reference)
                .textFieldStyle(.plain)
                .fontDesign(.monospaced)
                .accessibilityIdentifier(fieldIdentifier ?? "")
            if !images.isEmpty {
                Menu {
                    ForEach(images) { image in
                        Button(image.fullName) { reference = image.fullName }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a local image")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - Return-key sheet submission

extension View {
    /// Submits a sheet's primary action on Return from *any* field, not just the first one
    /// focused. A focused TextField's field editor swallows Return itself rather than forwarding
    /// it to the window's default button, so `.keyboardShortcut(.return)` on the primary button
    /// alone only fires when no field has focus. Attaching `.onSubmit` to the sheet's outermost
    /// content container instead catches Return bubbling up from every field inside it.
    ///
    /// `isEnabled` should mirror the primary button's own `.disabled` condition, and `action` its
    /// `action`, so Return and a button click always agree on when submission is allowed.
    ///
    /// One field type doesn't participate in this bubbling: a raw `NSViewRepresentable` like
    /// `NoAutoFillSecureField` needs its own bridge into `action` (see that type's `onSubmit`
    /// parameter), since SwiftUI's `.onSubmit` only observes its own `TextField`/`SecureField`.
    func submitsOnReturn(when isEnabled: Bool, action: @escaping () -> Void) -> some View {
        onSubmit { if isEnabled { action() } }
    }
}
