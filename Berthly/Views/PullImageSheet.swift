import SwiftUI
import TerminalProgress

// MARK: - Pull Progress State

@MainActor
@Observable
private final class PullProgressState {
    struct LogLine: Identifiable {
        let id = UUID()
        let tag: String
        let text: String
    }

    var completedItems: Int = 0
    var totalItems: Int = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var logLines: [LogLine] = []

    private var hasLoggedManifest = false

    func start(reference: String) {
        completedItems = 0; totalItems = 0; downloadedBytes = 0; totalBytes = 0
        hasLoggedManifest = false
        logLines = [LogLine(tag: "PULL", text: "container image pull \(reference)")]
    }

    func markFetchingComplete() {
        if totalItems > 0 {
            let blobWord = totalItems == 1 ? "blob" : "blobs"
            let sizePart = totalBytes > 0 ? " · \(formatSize(totalBytes))" : ""
            logLines.append(LogLine(tag: "PULL", text: "fetching complete · \(totalItems) \(blobWord)\(sizePart)"))
        } else {
            logLines.append(LogLine(tag: "PULL", text: "fetching complete · all layers cached"))
        }
    }

    func appendLog(tag: String, text: String) {
        logLines.append(LogLine(tag: tag, text: text))
    }

    func markDone(reference: String) {
        logLines.append(LogLine(tag: "DONE", text: "\(reference) ready · pulled to local store"))
    }

    func handle(_ events: [ProgressUpdateEvent]) {
        var dTotalSize: Int64 = 0
        var dSize: Int64 = 0
        var dItems: Int = 0
        var dTotalItems: Int = 0
        for event in events {
            switch event {
            case .addTotalSize(let n):  dTotalSize += n
            case .addSize(let n):       dSize += n
            case .addItems(let n):      dItems += n
            case .addTotalItems(let n): dTotalItems += n
            default: break
            }
        }
        totalBytes      += dTotalSize
        downloadedBytes += dSize
        completedItems  += dItems
        totalItems      += dTotalItems

        if !hasLoggedManifest && dTotalSize > 0 {
            hasLoggedManifest = true
            logLines.append(LogLine(tag: "PULL", text: "resolving manifest ✓"))
        }
    }

    var fraction: Double? {
        if totalBytes > 0 { return min(1.0, Double(downloadedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return min(1.0, Double(completedItems) / Double(totalItems)) }
        return nil
    }

    var percentText: String {
        guard let f = fraction else { return "" }
        return "\(Int(f * 100))%"
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }

    var handler: ProgressUpdateHandler {
        { [weak self] events in
            guard let self else { return }
            await self.handle(events)
        }
    }
}

// MARK: - Pull Image Sheet

struct PullImageSheet: View {
    var onOpenRegistries: () -> Void = {}

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var allowInsecure = false
    @State private var showAdvanced = false
    @State private var isPulling = false
    @State private var isDone = false
    @State private var errorMessage: String?
    @State private var pullProgress = PullProgressState()
    @State private var pullTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull Image")
                        .font(.headline)
                    Text("Pulls from Docker Hub or any public registry — no sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 14) {
                if isPulling || isDone {
                    activeContent
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Spacer()
                if isDone {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else if isPulling {
                    Button("Cancel") { cancelPull() }
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Cancel") { dismiss() }
                    Button("Pull") { startPull() }
                        .buttonStyle(.borderedProminent)
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image reference")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("ubuntu:24.04", text: $reference)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startPull() }
        }

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Anonymous pull — no sign-in needed. Short names resolve against \(Text("docker.io/library").fontDesign(.monospaced)).")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 3) {
                    Text("For a private image,")
                    Button { onOpenRegistries() } label: {
                        Text("sign in via Registries.").underline()
                    }
                    .buttonStyle(.link)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                PlatformPicker(title: "Platform", selection: $platformChoice)
                Toggle(isOn: $allowInsecure) {
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
        } label: {
            Text("Advanced")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        // Progress bar — visible while pulling, hidden when done
        if isPulling {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pulling image")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(pullProgress.percentText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let fraction = pullProgress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }

        // Log output box
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pullProgress.logLines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(line.tag)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 36, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.tag == "DONE" ? Color.green : Color.primary)
                        }
                        .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .onChange(of: pullProgress.logLines.count) { _, _ in
                if let last = pullProgress.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }

        // Success box — visible when done
        if isDone {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image pulled")
                        .font(.callout.weight(.semibold))
                    Text(reference)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
        }
    }

    private func startPull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !isPulling else { return }
        isPulling = true
        isDone = false
        errorMessage = nil
        pullProgress.start(reference: ref)
        let platform = platformChoice.rawValue.isEmpty ? nil : platformChoice.rawValue
        pullTask = Task {
            do {
                try await service.pullImage(
                    reference: ref,
                    platform: platform,
                    insecure: allowInsecure,
                    progress: pullProgress.handler,
                    onUnpacking: {
                        pullProgress.markFetchingComplete()
                        pullProgress.appendLog(tag: "PULL", text: "unpacking image")
                    }
                )
                pullProgress.markDone(reference: ref)
                isPulling = false
                isDone = true
            } catch is CancellationError {
                isPulling = false
            } catch {
                errorMessage = error.localizedDescription
                isPulling = false
            }
            pullTask = nil
        }
    }

    private func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPulling = false
        errorMessage = nil
    }
}

#Preview {
    PullImageSheet()
        .environment(MockContainerService() as ContainerServiceBase)
}
