import SwiftUI

// MARK: - Build state

@MainActor
@Observable
private final class BuildState {
    struct LogLine: Identifiable { let id = UUID(); let text: String }

    enum Result {
        case success(reference: String)
        case failure(message: String)
    }

    var logLines: [LogLine] = []
    var isBuilding = false
    var result: Result? = nil
    var buildTask: Task<Void, Never>? = nil

    func appendLog(_ text: String) {
        logLines.append(LogLine(text: text))
    }
}

// MARK: - Sheet

struct BuildImageSheet: View {
    let service: ContainerServiceBase
    let prefillTag: String?
    let prefillContext: BuildContext?

    @Environment(\.dismiss) private var dismiss

    @State private var tag: String
    @State private var contextPath: String
    @State private var dockerfilePath: String
    @State private var platformChoice: SheetPlatformChoice
    @State private var buildArgs: [KeyValuePair]
    @State private var noCache: Bool

    @State private var showAdvanced = false
    @State private var labels: [KeyValuePair]
    @State private var target: String
    @State private var cpus: String = ""
    @State private var memory: String = ""
    @State private var secrets: [StringEntry] = []
    @State private var pull: Bool = false

    @State private var state = BuildState()

    init(service: ContainerServiceBase, prefillTag: String? = nil, prefillContext: BuildContext? = nil) {
        self.service = service
        self.prefillTag = prefillTag
        self.prefillContext = prefillContext
        _tag = State(initialValue: prefillTag ?? "")
        _contextPath = State(initialValue: prefillContext?.contextPath ?? "")
        _dockerfilePath = State(initialValue: prefillContext?.dockerfilePath ?? "")
        _platformChoice = State(initialValue: SheetPlatformChoice(rawValue: prefillContext?.platform ?? "") ?? .default)
        _buildArgs = State(initialValue: (prefillContext?.buildArgs ?? [:]).sorted { $0.key < $1.key }.map { KeyValuePair(key: $0.key, value: $0.value) })
        _noCache = State(initialValue: prefillContext?.noCache ?? false)
        _labels = State(initialValue: (prefillContext?.labels ?? [:]).sorted { $0.key < $1.key }.map { KeyValuePair(key: $0.key, value: $0.value) })
        _target = State(initialValue: prefillContext?.target ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hammer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prefillTag != nil ? "Rebuild Image" : "Build Image")
                        .font(.headline)
                    Text("Build from a Dockerfile or Containerfile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.isBuilding || state.result != nil {
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
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                case nil:
                    if state.isBuilding {
                        Button("Cancel") { cancelBuild() }.keyboardShortcut(.cancelAction)
                        Button {} label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Building…")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    } else {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button("Build") { startBuild() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canBuild)
                            .keyboardShortcut(.return)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    private var canBuild: Bool {
        !tag.trimmingCharacters(in: .whitespaces).isEmpty &&
        !contextPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tag")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("local/myapp:1.0", text: $tag)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { if canBuild { startBuild() } }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Build context")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(contextPath.isEmpty ? "Choose a folder…" : contextPath)
                    .font(contextPath.isEmpty ? .callout : .system(.callout, design: .monospaced))
                    .foregroundStyle(contextPath.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Browse…") { pickContextDir() }
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Dockerfile")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Dockerfile (auto-detected)", text: $dockerfilePath)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                Button("Browse…") { pickDockerfile() }
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            Text("Defaults to Dockerfile or Containerfile in the build context.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        PlatformPicker(title: "Platform", selection: $platformChoice)

        KeyValueEditor(title: "Build arguments", keyPlaceholder: "ARG_NAME", valuePlaceholder: "value", pairs: $buildArgs)

        Toggle("Disable build cache", isOn: $noCache)
            .toggleStyle(.checkbox)

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                KeyValueEditor(title: "Labels", keyPlaceholder: "key", valuePlaceholder: "value", pairs: $labels)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Target stage")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Stage name in a multi-stage build", text: $target)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPUs")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 4", text: $cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. 2g", text: $memory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                StringListEditor(
                    title: "Secrets",
                    placeholder: "id=mysecret,src=/path/to/file",
                    helpText: "Format: id=<key>[,env=ENV_VAR|,src=/local/path]",
                    entries: $secrets
                )

                Toggle("Pull latest base images", isOn: $pull)
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .onChange(of: state.logLines.count) { _, _ in
                if let last = state.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }

        switch state.result {
        case .success(let ref):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image built successfully")
                        .font(.callout.weight(.semibold))
                    Text(ref)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
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
                    .lineLimit(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))

        case nil:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func pickContextDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the build context directory"
        if panel.runModal() == .OK, let url = panel.url {
            contextPath = url.path(percentEncoded: false)
        }
    }

    private func pickDockerfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Dockerfile or Containerfile"
        if panel.runModal() == .OK, let url = panel.url {
            dockerfilePath = url.path(percentEncoded: false)
        }
    }

    private func dict(from pairs: [KeyValuePair]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = pair.value
        }
        return result
    }

    private func startBuild() {
        let ref = tag.trimmingCharacters(in: .whitespaces)
        let ctx = contextPath.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !ctx.isEmpty, !state.isBuilding else { return }
        let df = dockerfilePath.trimmingCharacters(in: .whitespaces)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let argsDict = dict(from: buildArgs)
        let labelsDict = dict(from: labels)
        let targetTrimmed = target.trimmingCharacters(in: .whitespaces)
        let cpusValue = Int(cpus.trimmingCharacters(in: .whitespaces))
        let memoryTrimmed = memory.trimmingCharacters(in: .whitespaces)
        let secretValues = secrets.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        state.isBuilding = true
        state.result = nil
        state.logLines = []

        let options = BuildOptions(
            reference: ref,
            contextPath: ctx,
            dockerfilePath: df.isEmpty ? nil : df,
            platform: platform,
            buildArgs: argsDict,
            noCache: noCache,
            labels: labelsDict,
            target: targetTrimmed.isEmpty ? nil : targetTrimmed,
            cpus: cpusValue,
            memory: memoryTrimmed.isEmpty ? nil : memoryTrimmed,
            secrets: secretValues,
            pull: pull
        )

        state.buildTask = Task {
            do {
                try await service.buildImage(options: options, onLog: state.appendLog)
                service.saveBuildContext(
                    BuildContext(
                        contextPath: ctx,
                        dockerfilePath: df.isEmpty ? nil : df,
                        platform: platform,
                        buildArgs: argsDict,
                        labels: labelsDict,
                        target: targetTrimmed.isEmpty ? nil : targetTrimmed,
                        noCache: noCache
                    ),
                    for: ref
                )
                state.result = .success(reference: ref)
            } catch is CancellationError {
                state.result = nil
            } catch {
                state.result = .failure(message: error.localizedDescription)
            }
            state.isBuilding = false
            state.buildTask = nil
        }
    }

    private func cancelBuild() {
        state.buildTask?.cancel()
        state.buildTask = nil
        state.isBuilding = false
        state.result = nil
        state.logLines = []
    }
}

// MARK: - Previews

#Preview("Build – empty") {
    BuildImageSheet(service: MockContainerService())
}

#Preview("Rebuild – with context") {
    BuildImageSheet(
        service: MockContainerService(),
        prefillTag: "local/web:1.4",
        prefillContext: BuildContext(
            contextPath: "/Users/dev/projects/web",
            buildArgs: ["NODE_ENV": "production"],
            target: "release"
        )
    )
}

#Preview("Rebuild – CLI built (tag only)") {
    BuildImageSheet(service: MockContainerService(), prefillTag: "local/proxy:1.25")
}
