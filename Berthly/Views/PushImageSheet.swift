import SwiftUI
import TerminalProgress

// MARK: - Push Image Sheet

/// Pushes a local image to a registry. Unlike pull, push acts on a *specific* image and needs a
/// registry-qualified destination — so the sheet shows the local source read-only and lets the
/// user edit the destination reference (which retags before pushing). It also surfaces whether the
/// destination host is signed in, since a missing credential is the most common push failure.
struct PushImageSheet: View {
    let image: ContainerImage

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var destination: String
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var allowInsecure = false
    @State private var showAdvanced = false
    @State private var isPushing = false
    @State private var isDone = false
    @State private var errorMessage: String?
    @State private var pushProgress = TransferProgressState.push()
    @State private var pushTask: Task<Void, Never>?

    init(image: ContainerImage) {
        self.image = image
        _destination = State(initialValue: image.fullName)
    }

    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespaces) }
    private var host: String? { registryHost(forReference: trimmedDestination) }
    private var isSignedIn: Bool { host.map { h in service.registries.contains { $0.host == h } } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push Image")
                        .font(.headline)
                    Text("Uploads a local image to a registry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if isPushing || isDone {
                    activeContent
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    // A banner, not a caption line: a failed push can still leave a local retag
                    // behind (retagging and the network upload are separate steps — the same as
                    // `docker tag && docker push`), so the failure needs to be impossible to miss,
                    // or a stray successful-looking row with no matching remote push reads as a bug.
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push failed")
                                .font(.callout.weight(.semibold))
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                if isDone {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else if isPushing {
                    Button("Cancel") { cancelPush() }.keyboardShortcut(.cancelAction)
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Push") { startPush() }
                        .buttonStyle(.borderedProminent)
                        // `host == nil` is a guaranteed failure, not a soft warning — see
                        // `registryHint`'s doc comment for why this tool never infers Docker Hub.
                        .disabled(trimmedDestination.isEmpty || host == nil)
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("pushSubmitButton")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        // `service.registries` is lazily loaded — only `RegistriesListView`'s own `.task` and
        // sign-in/out populate it — so without this, `isSignedIn` can read stale/empty (false
        // negative) for a user who's genuinely signed in but hasn't opened the Registries pane
        // this session. Loads every time the sheet appears, matching RegistriesListView's pattern.
        .task { await service.loadRegistries() }
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(image.fullName)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Destination")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("registry.example.com/team/web:1.0", text: $destination)
                .accessibilityIdentifier("pushDestinationField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startPush() }
        }

        registryHint

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

    /// Up-front auth/host feedback: green when the target host is signed in, amber when it isn't.
    /// A *missing* host is a hard blocker, not a soft warning — unlike `docker push`, this app's
    /// `container image push` never infers Docker Hub for a domain-less reference (confirmed against
    /// `ImagePush.swift`: it calls `ClientImage.get` then `.push` with no normalization step), so a
    /// reference like `user/repo:tag` fails outright with "could not extract host from reference".
    /// The Push button is disabled for this case (see `body`), and the banner offers a one-tap fix
    /// instead of just describing the problem.
    @ViewBuilder
    private var registryHint: some View {
        let signedIn = isSignedIn
        let color: Color = host == nil ? Color.statusPaused : (signedIn ? .green : Color.statusPaused)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: host == nil ? "exclamationmark.triangle.fill" : (signedIn ? "lock.open.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(color)
                    .imageScale(.small)
                    .padding(.top, 1)
                Text(hintText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if host == nil {
                Button("Use docker.io/\(trimmedDestination)") {
                    destination = "docker.io/\(trimmedDestination)"
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.2), lineWidth: 0.5))
    }

    private var hintText: String {
        guard let host else {
            return "No registry host in the destination. Add a host to push."
        }
        if isSignedIn {
            return "Signed in to \(host)."
        }
        return "Not signed in to \(host). If the push is rejected, add credentials in Registries first."
    }

    @ViewBuilder
    private var activeContent: some View {
        if isPushing {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pushing image")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(pushProgress.percentText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let fraction = pushProgress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pushProgress.logLines) { line in
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
            .onChange(of: pushProgress.logLines.count) { _, _ in
                if let last = pushProgress.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }

        if isDone {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image pushed")
                        .font(.callout.weight(.semibold))
                    Text(trimmedDestination)
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

    private func startPush() {
        let dest = trimmedDestination
        guard !dest.isEmpty, !isPushing else { return }
        isPushing = true
        isDone = false
        errorMessage = nil
        pushProgress.start(reference: dest)
        let platform = platformChoice.rawValue.isEmpty ? nil : platformChoice.rawValue
        pushTask = Task {
            do {
                try await service.pushImage(
                    reference: image.fullName,
                    destination: dest,
                    platform: platform,
                    insecure: allowInsecure,
                    progress: pushProgress.handler
                )
                pushProgress.markDone(reference: dest)
                isPushing = false
                isDone = true
            } catch is CancellationError {
                isPushing = false
            } catch {
                errorMessage = error.localizedDescription
                isPushing = false
            }
            pushTask = nil
        }
    }

    private func cancelPush() {
        pushTask?.cancel()
        pushTask = nil
        isPushing = false
        errorMessage = nil
    }
}

#Preview {
    let mock = MockContainerService()
    return PushImageSheet(image: mock.images[0])
        .environment(mock as ContainerServiceBase)
}
