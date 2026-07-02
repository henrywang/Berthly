import SwiftUI

// MARK: - Key/value row editor (build args, labels, env vars)

struct KeyValuePair: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

struct KeyValueEditor: View {
    let title: String
    let keyPlaceholder: String
    let valuePlaceholder: String
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
                        Text("=").foregroundStyle(.tertiary)
                        TextField(valuePlaceholder, text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button {
                            pairs.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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
    let title: String
    let placeholder: String
    var helpText: String? = nil
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
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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
    let title: String
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
                        Text(":").foregroundStyle(.tertiary)
                        TextField("container", text: $entry.containerPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 70)
                        Picker("", selection: $entry.proto) {
                            ForEach(PortProtocolChoice.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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
    let title: String
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
                        if entry.type != .tmpfs {
                            TextField("source", text: $entry.source)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
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
    let title: String
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
