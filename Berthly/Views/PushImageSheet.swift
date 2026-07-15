// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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
            SheetHeader(
                systemImage: "square.and.arrow.up",
                title: "Push Image",
                subtitle: "Uploads a local image to a registry"
            )

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
                    SheetStatusCallout(symbol: "xmark.octagon.fill", tint: .red, title: "Push failed") {
                        SheetCalloutDetail(text: error, monospaced: false, lineLimit: 4)
                    }
                }
            }
            .padding(20)

            Divider()

            SheetSubmitFooter(
                phase: isDone ? .done : (isPushing ? .working : .idle),
                submitLabel: "Push",
                // `host == nil` is a guaranteed failure, not a soft warning — see `registryHint`'s
                // doc comment for why this tool never infers Docker Hub.
                canSubmit: !trimmedDestination.isEmpty && host != nil,
                submitIdentifier: "pushSubmitButton",
                onCancel: cancelPush,
                onSubmit: startPush
            )
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
        SheetField("Source") {
            SheetMonospacedValue(text: image.fullName)
        }

        SheetField("Destination") {
            TextField("registry.example.com/team/web:1.0", text: $destination)
                .accessibilityIdentifier("pushDestinationField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startPush() }
        }

        registryHint

        SheetAdvancedSection(isExpanded: $showAdvanced) {
            PlatformPicker(title: "Platform", selection: $platformChoice)
            InsecureRegistryToggle(isOn: $allowInsecure)
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
        SheetCallout(tint: color) {
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
        }
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
            TransferProgressHeader(title: "Pushing image", progress: pushProgress)
        }

        TransferLogView(lines: pushProgress.logLines)

        if isDone {
            SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Image pushed", alignment: .center) {
                SheetCalloutDetail(text: trimmedDestination)
            }
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
