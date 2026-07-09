import SwiftUI

// MARK: - Run state

@MainActor
@Observable
private final class RunState {
    enum Result {
        /// `newContainerID` drives the success state's "Show Container" button — resolved by
        /// diffing the service's container list against `preRunIDs` (the run itself refreshes
        /// the list before returning), which works even when the name was auto-generated.
        case success(reference: String, output: String, newContainerID: String?)
        case failure(message: String)
    }

    var isRunning = false
    var result: Result? = nil
    var runTask: Task<Void, Never>? = nil
}

// MARK: - Sheet

/// Groups the ~30 container-run options into tabs so the sheet isn't one long scroll of
/// everything at once. MachineCreateSheet has too few fields (6) to need this — it stays a
/// flat form.
private enum RunCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case storage = "Storage"
    case network = "Network"
    case dns = "DNS"
    case resources = "Resources"
    case environment = "Environment"
    case security = "Security"

    var id: String { rawValue }

    /// Localizable display title. A `switch` of string literals (rather than reusing `rawValue`)
    /// so each name is extracted into the String Catalog — `LocalizedStringKey(rawValue)` from a
    /// runtime string wouldn't be picked up by Xcode's literal extraction.
    var titleKey: LocalizedStringKey {
        switch self {
        case .general:     "General"
        case .storage:     "Storage"
        case .network:     "Network"
        case .dns:         "DNS"
        case .resources:   "Resources"
        case .environment: "Environment"
        case .security:    "Security"
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .storage:     return "externaldrive"
        case .network:     return "network"
        case .dns:         return "globe"
        case .resources:   return "cpu"
        case .environment: return "leaf"
        case .security:    return "lock.shield"
        }
    }
}

struct RunContainerSheet: View {
    let service: ContainerServiceBase

    @Environment(\.dismiss) private var dismiss
    @Environment(MenuBarBridge.self) private var bridge

    @State private var selectedCategory: RunCategory = .general

    @State private var reference = ""
    @State private var name = ""
    @State private var command = ""
    @State private var ports: [PortEntry] = []
    @State private var volumes: [StringEntry] = []
    @State private var mounts: [MountEntry] = []
    @State private var env: [KeyValuePair] = []
    @State private var envFile: [StringEntry] = []
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var startImmediately = true
    @State private var attachAndShowOutput = false
    @State private var removeWhenStopped = false

    @State private var labels: [KeyValuePair] = []
    @State private var networks: [StringEntry] = []
    @State private var workdir = ""
    @State private var user = ""
    @State private var entrypoint = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var readOnly = false
    @State private var initProcess = false
    @State private var rosetta = false
    @State private var ssh = false
    @State private var shmSize = ""
    @State private var tmpfs: [StringEntry] = []
    @State private var ulimits: [StringEntry] = []
    @State private var insecureRegistry = false
    @State private var interactive = false
    @State private var tty = false
    @State private var virtualization = false
    @State private var capAdd: [StringEntry] = []
    @State private var capDrop: [StringEntry] = []
    @State private var cidFile = ""
    @State private var dns: [StringEntry] = []
    @State private var dnsDomain = ""
    @State private var dnsOptions: [StringEntry] = []
    @State private var dnsSearch: [StringEntry] = []
    @State private var noDns = false

    @State private var state = RunState()

    init(service: ContainerServiceBase, initialReference: String = "") {
        self.service = service
        _reference = State(initialValue: initialReference)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Container")
                        .font(.headline)
                    Text("Start a new container from an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            if state.isRunning || state.result != nil {
                ScrollView {
                    activeContent
                        .padding(20)
                }
                .frame(maxHeight: 520)
            } else {
                idleContent
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                switch state.result {
                case .success(_, _, let newContainerID):
                    if let newContainerID {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Show Container") {
                            // The next thing a user does after running is almost always "go look
                            // at it" — reuse the selection intent the menu bar rows use.
                            bridge.pendingIntent = .selectCompute(.container(newContainerID))
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                    } else {
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return)
                    }
                case .failure:
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                case nil:
                    if state.isRunning {
                        Button("Cancel") { cancelRun() }.keyboardShortcut(.cancelAction)
                        Button {} label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(progressLabel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    } else {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button(submitLabel) { startSubmit() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canRun)
                            .keyboardShortcut(.return)
                            .accessibilityIdentifier("runSubmitButton")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 720)
        .submitsOnReturn(when: canRun, action: startSubmit)
    }

    private var canRun: Bool {
        !reference.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var submitLabel: String {
        startImmediately ? "Run" : "Create"
    }

    private var progressLabel: String {
        startImmediately ? "Starting…" : "Creating…"
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Image")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                LocalImageReferenceField(reference: $reference, images: service.images)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Optional — auto-generated if left blank", text: $name)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
        }
        .padding(20)
        .padding(.bottom, 0)

        containerCategorizedForm
    }

    // MARK: - Categorized sidebar form

    @ViewBuilder
    private var containerCategorizedForm: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(RunCategory.allCases) { category in
                    let modified = modifiedCount(for: category)
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack(spacing: 4) {
                            Label(category.titleKey, systemImage: category.icon)
                                .font(.callout)
                            Spacer(minLength: 4)
                            // With 7 tabs it's easy to forget a value set three tabs ago —
                            // the count marks every category holding non-default settings.
                            if modified > 0 {
                                Text("\(modified)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.berthlyAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.berthlyAccent.opacity(0.15), in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            selectedCategory == category ? Color.berthlyAccent.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(selectedCategory == category ? Color.berthlyAccent : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170, alignment: .top)
            .background(.background.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    containerCategoryFields
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 420)
    }

    /// How many non-default settings a category currently holds. Counting rules mirror what
    /// `startSubmit()` actually sends: blank/whitespace-only text and empty editor rows are
    /// defaults, and sub-options gated off by a parent toggle (attach without start, DNS fields
    /// under "Disable DNS") don't count.
    private func modifiedCount(for category: RunCategory) -> Int {
        func filled(_ s: String) -> Int { s.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1 }
        func filled(_ e: [StringEntry]) -> Int { e.count { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty } }

        switch category {
        case .general:
            return filled(command)
                + (platformChoice == .default ? 0 : 1)
                + (startImmediately ? 0 : 1)
                + (startImmediately && attachAndShowOutput ? 1 : 0)
                + (removeWhenStopped ? 1 : 0)
        case .storage:
            return filled(volumes)
                + mounts.count { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }
                + filled(tmpfs)
        case .network:
            return ports.count { !$0.hostPort.trimmingCharacters(in: .whitespaces).isEmpty
                                 || !$0.containerPort.trimmingCharacters(in: .whitespaces).isEmpty }
                + filled(networks)
        case .dns:
            if noDns { return 1 }
            return filled(dns) + filled(dnsDomain) + filled(dnsOptions) + filled(dnsSearch)
        case .resources:
            return filled(cpus) + filled(memory) + filled(shmSize) + filled(ulimits)
        case .environment:
            return env.count { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                + filled(envFile)
                + labels.count { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        case .security:
            return filled(workdir) + filled(user) + filled(entrypoint) + filled(cidFile)
                + [readOnly, initProcess, rosetta, ssh, interactive, tty, virtualization, insecureRegistry]
                    .count { $0 }
                + filled(capAdd) + filled(capDrop)
        }
    }

    @ViewBuilder
    private var containerCategoryFields: some View {
        switch selectedCategory {
        case .general:     generalFields
        case .storage:     storageFields
        case .network:     networkFields
        case .dns:         dnsFields
        case .resources:   resourcesFields
        case .environment: environmentFields
        case .security:    securityFields
        }
    }

    @ViewBuilder
    private var generalFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional override, e.g. npm start", text: $command)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
        }

        PlatformPicker(title: "Platform", selection: $platformChoice)

        Toggle("Start immediately", isOn: $startImmediately)
            .toggleStyle(.checkbox)
        if startImmediately {
            Toggle(isOn: $attachAndShowOutput) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attach and show output")
                    Text("For one-shot commands that exit, e.g. pwd — waits for the command to finish and shows what it printed. Don't use with a long-running service.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
        }
        Toggle("Remove when stopped", isOn: $removeWhenStopped)
            .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var storageFields: some View {
        StringListEditor(
            title: "Volumes",
            placeholder: "myvolume:/var/lib/data or /host/path:/container/path",
            entries: $volumes
        )
        MountRowsEditor(title: "Mounts", entries: $mounts)
        StringListEditor(title: "Tmpfs paths", placeholder: "/tmp/scratch", entries: $tmpfs)
    }

    private var defaultNetworkHelpText: String {
        guard let defaultNetwork = service.networks.first(where: \.isDefault) else {
            return "Attach to one or more networks. Leave empty for the standard network."
        }
        return "Attach to one or more networks. Leave empty to use the standard network (\(defaultNetwork.subnet))."
    }

    @ViewBuilder
    private var networkFields: some View {
        PortRowsEditor(title: "Ports", entries: $ports)
        NetworkListEditor(
            title: "Networks",
            helpText: defaultNetworkHelpText,
            availableNetworks: service.networks,
            entries: $networks
        )
    }

    @ViewBuilder
    private var dnsFields: some View {
        Toggle("Disable DNS configuration", isOn: $noDns)
            .toggleStyle(.checkbox)
        if !noDns {
            StringListEditor(title: "DNS servers", placeholder: "1.1.1.1", entries: $dns)
            VStack(alignment: .leading, spacing: 6) {
                Text("DNS domain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Optional", text: $dnsDomain)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            StringListEditor(title: "DNS options", placeholder: "ndots:5", entries: $dnsOptions)
            StringListEditor(title: "DNS search domains", placeholder: "corp.example.com", entries: $dnsSearch)
        }
    }

    @ViewBuilder
    private var resourcesFields: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPUs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("2", text: $cpus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("1g", text: $memory)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Shared memory size")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("64m", text: $shmSize)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 100)
        }
        StringListEditor(
            title: "Resource limits (ulimit)",
            placeholder: "nofile=1024:2048",
            entries: $ulimits
        )
    }

    @ViewBuilder
    private var environmentFields: some View {
        KeyValueEditor(title: "Environment variables", keyPlaceholder: "KEY", valuePlaceholder: "value", pairs: $env)
        StringListEditor(title: "Env files", placeholder: "/host/path/.env", entries: $envFile)
        KeyValueEditor(title: "Labels", keyPlaceholder: "key", valuePlaceholder: "value", pairs: $labels)
    }

    @ViewBuilder
    private var securityFields: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Working directory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("/app", text: $workdir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("User")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("name|uid[:gid]", text: $user)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Entrypoint override")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional", text: $entrypoint)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }

        Toggle("Read-only root filesystem", isOn: $readOnly)
            .toggleStyle(.checkbox)
        Toggle("Run an init process", isOn: $initProcess)
            .toggleStyle(.checkbox)
        Toggle("Enable Rosetta", isOn: $rosetta)
            .toggleStyle(.checkbox)
        Toggle("Forward SSH agent", isOn: $ssh)
            .toggleStyle(.checkbox)
        Toggle("Keep stdin open (-i)", isOn: $interactive)
            .toggleStyle(.checkbox)
        Toggle("Allocate a TTY (-t)", isOn: $tty)
            .toggleStyle(.checkbox)
        Toggle("Expose virtualization capabilities", isOn: $virtualization)
            .toggleStyle(.checkbox)

        StringListEditor(title: "Add capabilities", placeholder: "CAP_NET_RAW, or ALL", entries: $capAdd)
        StringListEditor(title: "Drop capabilities", placeholder: "CAP_SYS_ADMIN, or ALL", entries: $capDrop)

        VStack(alignment: .leading, spacing: 6) {
            Text("Container ID file")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional — path to write the container ID to", text: $cidFile)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }

        Toggle(isOn: $insecureRegistry) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow insecure registry")
                    .font(.caption.weight(.medium))
                Text("Forces HTTP instead of HTTPS. Only use for private registries without TLS.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Active / done

    @ViewBuilder
    private var activeContent: some View {
        switch state.result {
        case .success(let ref, let output, _):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(successLabel)
                            .font(.callout.weight(.semibold))
                        Text(ref)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
                if !output.isEmpty {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        case .failure(let msg):
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))

        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progressLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var successLabel: String {
        startImmediately ? "Container running" : "Container created"
    }

    // MARK: - Actions

    private func dict(from pairs: [KeyValuePair]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = pair.value
        }
        return result
    }

    private func portSpecs(from rows: [PortEntry]) -> [String] {
        rows.compactMap { row in
            let host = row.hostPort.trimmingCharacters(in: .whitespaces)
            let container = row.containerPort.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !container.isEmpty else { return nil }
            return "\(host):\(container)/\(row.proto.rawValue)"
        }
    }

    private func strings(from entries: [StringEntry]) -> [String] {
        entries.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func mountSpecs(from entries: [MountEntry]) -> [String] {
        entries.compactMap { entry in
            let target = entry.target.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            var parts = ["type=\(entry.type.rawValue)"]
            let source = entry.source.trimmingCharacters(in: .whitespaces)
            if entry.type != .tmpfs, !source.isEmpty {
                parts.append("source=\(source)")
            }
            parts.append("target=\(target)")
            if entry.readOnly { parts.append("readonly") }
            return parts.joined(separator: ",")
        }
    }

    private func startSubmit() {
        guard canRun, !state.isRunning else { return }
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        // Shell-style lexing, not a naive space split — `sh -c "echo hi"` must stay 3 words.
        let commandParts = ShellTokenizer.tokenize(command)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let workdirTrimmed = workdir.trimmingCharacters(in: .whitespaces)
        let userTrimmed = user.trimmingCharacters(in: .whitespaces)
        let entrypointTrimmed = entrypoint.trimmingCharacters(in: .whitespaces)
        let cpusValue = Int(cpus.trimmingCharacters(in: .whitespaces))
        let memoryTrimmed = memory.trimmingCharacters(in: .whitespaces)
        let shmSizeTrimmed = shmSize.trimmingCharacters(in: .whitespaces)
        let cidFileTrimmed = cidFile.trimmingCharacters(in: .whitespaces)
        let dnsDomainTrimmed = dnsDomain.trimmingCharacters(in: .whitespaces)

        state.isRunning = true
        state.result = nil

        let options = RunOptions(
            reference: ref,
            name: nameTrimmed.isEmpty ? nil : nameTrimmed,
            command: commandParts,
            ports: portSpecs(from: ports),
            volumes: strings(from: volumes),
            env: dict(from: env),
            platform: platform,
            start: startImmediately,
            attach: startImmediately && attachAndShowOutput,
            remove: removeWhenStopped,
            labels: dict(from: labels),
            networks: strings(from: networks),
            workdir: workdirTrimmed.isEmpty ? nil : workdirTrimmed,
            user: userTrimmed.isEmpty ? nil : userTrimmed,
            entrypoint: entrypointTrimmed.isEmpty ? nil : entrypointTrimmed,
            cpus: cpusValue,
            memory: memoryTrimmed.isEmpty ? nil : memoryTrimmed,
            readOnly: readOnly,
            initProcess: initProcess,
            rosetta: rosetta,
            ssh: ssh,
            shmSize: shmSizeTrimmed.isEmpty ? nil : shmSizeTrimmed,
            tmpfs: strings(from: tmpfs),
            mounts: mountSpecs(from: mounts),
            envFile: strings(from: envFile),
            ulimits: strings(from: ulimits),
            insecureRegistry: insecureRegistry,
            interactive: interactive,
            tty: tty,
            virtualization: virtualization,
            capAdd: strings(from: capAdd),
            capDrop: strings(from: capDrop),
            cidFile: cidFileTrimmed.isEmpty ? nil : cidFileTrimmed,
            dns: strings(from: dns),
            dnsDomain: dnsDomainTrimmed.isEmpty ? nil : dnsDomainTrimmed,
            dnsOptions: strings(from: dnsOptions),
            dnsSearch: strings(from: dnsSearch),
            noDns: noDns
        )

        // `runContainer` refreshes the container list before returning, so the new container is
        // whatever ID appears that wasn't here before — works even for auto-generated names.
        let preRunIDs = Set(service.containers.map(\.id))

        state.runTask = Task {
            do {
                let output = try await service.runContainer(options: options)
                let newID = service.containers.map(\.id).first { !preRunIDs.contains($0) }
                state.result = .success(
                    reference: nameTrimmed.isEmpty ? ref : nameTrimmed,
                    output: output,
                    newContainerID: newID
                )
            } catch is CancellationError {
                state.result = nil
            } catch {
                state.result = .failure(message: error.localizedDescription)
            }
            state.isRunning = false
            state.runTask = nil
        }
    }

    private func cancelRun() {
        state.runTask?.cancel()
        state.runTask = nil
        state.isRunning = false
        state.result = nil
    }
}

// MARK: - Preview

#Preview {
    RunContainerSheet(service: MockContainerService())
        .environment(MenuBarBridge())
}
