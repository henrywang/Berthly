// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Sheet

/// Build form + live log. The build itself runs as a `BuildJob` owned by the app-level
/// `BuildJobManager`, so this sheet can be dismissed ("Continue in Background") without
/// interrupting it; the toolbar builds indicator surfaces the result. Passing `existingJob`
/// reopens the sheet directly onto a running/finished job's log.
struct BuildImageSheet: View {
    let service: ContainerServiceBase
    let prefillTag: String?
    let prefillContext: BuildContext?
    let existingJob: BuildJob?

    @Environment(BuildJobManager.self) private var buildManager
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

    @State private var job: BuildJob?

    init(
        service: ContainerServiceBase,
        prefillTag: String? = nil,
        prefillContext: BuildContext? = nil,
        existingJob: BuildJob? = nil
    ) {
        self.service = service
        self.prefillTag = prefillTag
        self.prefillContext = prefillContext
        self.existingJob = existingJob
        _job = State(initialValue: existingJob)
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
                    Text(headerTitle)
                        .font(.headline)
                    Text("Build from a Dockerfile or Containerfile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // A plain ScrollView reports a small ideal height, so the sheet used to open with
            // the form cropped mid-control at the fold. While the collapsed form is short enough
            // to show whole, let the scroll view self-size to its content (fixedSize); once
            // Advanced expands or the build log takes over, switch to a fixed, scrolling height.
            let selfSizing = job == nil && !showAdvanced
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let job {
                        activeContent(job)
                    } else {
                        idleContent
                    }
                }
                .padding(20)
            }
            .fixedSize(horizontal: false, vertical: selfSizing)
            .frame(maxHeight: selfSizing ? nil : 520)

            Divider()

            // Footer
            HStack {
                Spacer()
                switch job?.status {
                case .succeeded:
                    Button("Done") { markSeenAndDismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                case .failed:
                    Button("Close") { markSeenAndDismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                case .building:
                    Button("Cancel Build") { cancelBuild() }
                    Button("Continue in Background") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.cancelAction)
                        .help("The build keeps running; find it under the Builds toolbar indicator")
                case nil:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Build") { startBuild() }
                        .accessibilityIdentifier("buildSubmitButton")
                        .buttonStyle(.borderedProminent)
                        .disabled(!canBuild)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .submitsOnReturn(when: canBuild, action: startBuild)
        // If the user watches the build finish right here, the result is already "seen" —
        // don't leave a stale unseen badge on the toolbar indicator.
        .onChange(of: job?.isFinished ?? false) { _, finished in
            if finished { job?.seen = true }
        }
        .onAppear {
            if existingJob?.isFinished == true { existingJob?.seen = true }
        }
    }

    private var headerTitle: String {
        if existingJob != nil { return "Build Log" }
        return prefillTag != nil ? "Rebuild Image" : "Build Image"
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
            HStack(spacing: 6) {
                TextField("local/myapp:1.0", text: $tag)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .accessibilityIdentifier("buildTagField")
                // Existing local tags as one-click suggestions — rebuilding an image you
                // already have is the common case, so don't make the user retype the tag.
                if !service.images.isEmpty {
                    Menu {
                        ForEach(service.images) { image in
                            Button(image.fullName) { tag = image.fullName }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Reuse an existing tag")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Build context")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                // A typeable path field beside Browse: paste a path instead of hunting through
                // a panel, and it gives UI tests a way to set the context without driving the
                // system open panel. Mirrors the Dockerfile field below.
                TextField("Choose a folder…", text: $contextPath)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("buildContextField")
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
                    .accessibilityIdentifier("buildDockerfileField")
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
                        TextField("4", text: $cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("2g", text: $memory)
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
    private func activeContent(_ job: BuildJob) -> some View {
        Text(job.reference)
            .font(.caption)
            .fontDesign(.monospaced)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(job.logLines) { line in
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
            .onChange(of: job.logLines.count) { _, _ in
                if let last = job.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }

        switch job.status {
        case .succeeded:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image built successfully")
                        .font(.callout.weight(.semibold))
                    Text(job.reference)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        case .failed(let msg):
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

        case .building:
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
        guard !ref.isEmpty, !ctx.isEmpty, job == nil else { return }
        let df = dockerfilePath.trimmingCharacters(in: .whitespaces)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let targetTrimmed = target.trimmingCharacters(in: .whitespaces)
        let memoryTrimmed = memory.trimmingCharacters(in: .whitespaces)

        let options = BuildOptions(
            reference: ref,
            contextPath: ctx,
            dockerfilePath: df.isEmpty ? nil : df,
            platform: platform,
            buildArgs: dict(from: buildArgs),
            noCache: noCache,
            labels: dict(from: labels),
            target: targetTrimmed.isEmpty ? nil : targetTrimmed,
            cpus: Int(cpus.trimmingCharacters(in: .whitespaces)),
            memory: memoryTrimmed.isEmpty ? nil : memoryTrimmed,
            secrets: secrets.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            pull: pull
        )

        job = buildManager.start(options: options, service: service)
        // First build is the natural moment to ask for notification permission — the build
        // may finish while the user is elsewhere, and the grant is settled by then.
        BuildNotifier.shared.prepare()
    }

    private func cancelBuild() {
        guard let job else { return }
        buildManager.cancel(job)
        // A job opened from the builds indicator has no form behind it to fall back to.
        if existingJob != nil {
            dismiss()
        } else {
            self.job = nil
        }
    }

    private func markSeenAndDismiss() {
        job?.seen = true
        dismiss()
    }
}

// MARK: - Previews

#Preview("Build – empty") {
    BuildImageSheet(service: MockContainerService())
        .environment(BuildJobManager())
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
    .environment(BuildJobManager())
}

#Preview("Rebuild – CLI built (tag only)") {
    BuildImageSheet(service: MockContainerService(), prefillTag: "local/proxy:1.25")
        .environment(BuildJobManager())
}
