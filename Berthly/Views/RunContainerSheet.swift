import SwiftUI

// MARK: - Run state

@MainActor
@Observable
private final class RunState {
    enum Result {
        case success(reference: String, output: String)
        case failure(message: String)
    }

    var isRunning = false
    var result: Result? = nil
    var runTask: Task<Void, Never>? = nil
}

// MARK: - Sheet

private enum RunTargetType: String, CaseIterable {
    case container = "Container"
    case machine = "Machine"
}

private enum HomeMountChoice: String, CaseIterable {
    case `default` = ""
    case rw = "rw"
    case ro = "ro"
    case none = "none"

    var label: String {
        switch self {
        case .default: return "Default (rw)"
        case .rw:      return "Read/write"
        case .ro:      return "Read-only"
        case .none:    return "None"
        }
    }
}

struct RunContainerSheet: View {
    let service: ContainerServiceBase

    @Environment(\.dismiss) private var dismiss

    @State private var targetType: RunTargetType = .container

    @State private var reference = ""
    @State private var name = ""
    @State private var command = ""
    @State private var ports: [PortEntry] = []
    @State private var volumes: [StringEntry] = []
    @State private var env: [KeyValuePair] = []
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var startImmediately = true
    @State private var attachAndShowOutput = false
    @State private var removeWhenStopped = false

    // Machine-only main fields
    @State private var machineCpus = ""
    @State private var machineMemory = ""
    @State private var bootImmediately = true

    // Machine-only advanced fields
    @State private var homeMountChoice: HomeMountChoice = .default
    @State private var setDefault = false

    @State private var showAdvanced = false
    @State private var labels: [KeyValuePair] = []
    @State private var network = ""
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

    init(service: ContainerServiceBase) {
        self.service = service
    }

    fileprivate init(service: ContainerServiceBase, targetType: RunTargetType) {
        self.service = service
        _targetType = State(initialValue: targetType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: targetType == .container ? "shippingbox" : "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(targetType == .container ? "Run container" : "Create machine")
                        .font(.headline)
                    Text(targetType == .container ? "Start a new container from an image" : "Provision a new container machine from an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.isRunning || state.result != nil {
                        activeContent
                    } else {
                        idleContent
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 520)

            Divider()

            // Footer
            HStack {
                Spacer()
                switch state.result {
                case .success:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                case .failure:
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                case nil:
                    if state.isRunning {
                        Button("Cancel") { cancelRun() }
                        Button {} label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(progressLabel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    } else {
                        Button("Cancel") { dismiss() }
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
        .frame(width: 520)
    }

    private var canRun: Bool {
        !reference.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var submitLabel: String {
        switch targetType {
        case .container: return startImmediately ? "Run" : "Create"
        case .machine:   return "Create"
        }
    }

    private var progressLabel: String {
        switch targetType {
        case .container: return startImmediately ? "Starting…" : "Creating…"
        case .machine:   return "Creating…"
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        Picker("Type", selection: $targetType) {
            ForEach(RunTargetType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        VStack(alignment: .leading, spacing: 6) {
            Text("Image")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("local/myapp:1.0", text: $reference)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { if canRun { startSubmit() } }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional — auto-generated if left blank", text: $name)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
        }

        switch targetType {
        case .container: containerFields
        case .machine:   machineFields
        }
    }

    @ViewBuilder
    private var containerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional override, e.g. npm start", text: $command)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
        }

        PortRowsEditor(title: "Ports", entries: $ports)

        StringListEditor(
            title: "Volumes",
            placeholder: "myvolume:/var/lib/data or /host/path:/container/path",
            entries: $volumes
        )

        KeyValueEditor(title: "Environment variables", keyPlaceholder: "KEY", valuePlaceholder: "value", pairs: $env)

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

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                KeyValueEditor(title: "Labels", keyPlaceholder: "key", valuePlaceholder: "value", pairs: $labels)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Network")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Optional — defaults to the standard network", text: $network)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }

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

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPUs")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 2", text: $cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 1g", text: $memory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared memory size")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. 64m", text: $shmSize)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 100)
                }

                StringListEditor(title: "Tmpfs paths", placeholder: "/tmp/scratch", entries: $tmpfs)

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
            .padding(.top, 10)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var machineFields: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPUs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. 4", text: $machineCpus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. 8G", text: $machineMemory)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }

        PlatformPicker(title: "Platform", selection: $platformChoice)

        Toggle("Boot immediately", isOn: $bootImmediately)
            .toggleStyle(.checkbox)

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Home directory mount")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Home directory mount", selection: $homeMountChoice) {
                        ForEach(HomeMountChoice.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle("Set as default machine", isOn: $setDefault)
                    .toggleStyle(.checkbox)

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
            .padding(.top, 10)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Active / done

    @ViewBuilder
    private var activeContent: some View {
        switch state.result {
        case .success(let ref, let output):
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
        switch targetType {
        case .container: return startImmediately ? "Container running" : "Container created"
        case .machine:   return "Machine created"
        }
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

    private func startSubmit() {
        guard canRun, !state.isRunning else { return }
        switch targetType {
        case .container: startContainerRun()
        case .machine:   startMachineCreate()
        }
    }

    private func startContainerRun() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        let commandParts = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map(String.init)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let networkTrimmed = network.trimmingCharacters(in: .whitespaces)
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
            network: networkTrimmed.isEmpty ? nil : networkTrimmed,
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

        state.runTask = Task {
            do {
                let output = try await service.runContainer(options: options)
                state.result = .success(reference: nameTrimmed.isEmpty ? ref : nameTrimmed, output: output)
            } catch is CancellationError {
                state.result = nil
            } catch {
                state.result = .failure(message: error.localizedDescription)
            }
            state.isRunning = false
            state.runTask = nil
        }
    }

    private func startMachineCreate() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let cpusValue = Int(machineCpus.trimmingCharacters(in: .whitespaces))
        let memoryTrimmed = machineMemory.trimmingCharacters(in: .whitespaces)
        let homeMount = homeMountChoice == .default ? nil : homeMountChoice.rawValue

        state.isRunning = true
        state.result = nil

        let options = MachineCreateOptions(
            reference: ref,
            name: nameTrimmed.isEmpty ? nil : nameTrimmed,
            platform: platform,
            cpus: cpusValue,
            memory: memoryTrimmed.isEmpty ? nil : memoryTrimmed,
            homeMount: homeMount,
            boot: bootImmediately,
            setDefault: setDefault,
            insecureRegistry: insecureRegistry
        )

        state.runTask = Task {
            do {
                try await service.createMachine(options: options)
                state.result = .success(reference: nameTrimmed.isEmpty ? ref : nameTrimmed, output: "")
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

// MARK: - Previews

#Preview("Run – empty") {
    RunContainerSheet(service: MockContainerService())
}

#Preview("Run – machine") {
    RunContainerSheet(service: MockContainerService(), targetType: .machine)
}
