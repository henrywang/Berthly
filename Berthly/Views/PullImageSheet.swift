// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI
import TerminalProgress

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
    @State private var pullProgress = TransferProgressState.pull()
    @State private var pullTask: Task<Void, Never>?

    init(initialReference: String = "", initiallyInsecure: Bool = false, onOpenRegistries: @escaping () -> Void = {}) {
        self.onOpenRegistries = onOpenRegistries
        _reference = State(initialValue: initialReference)
        _allowInsecure = State(initialValue: initiallyInsecure)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "globe",
                title: "Pull Image",
                subtitle: "Pulls from Docker Hub or any public registry — no sign-in"
            )

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

            SheetSubmitFooter(
                phase: isDone ? .done : (isPulling ? .working : .idle),
                submitLabel: "Pull",
                canSubmit: !reference.trimmingCharacters(in: .whitespaces).isEmpty,
                submitIdentifier: "pullSubmitButton",
                onCancel: cancelPull,
                onSubmit: startPull
            )
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        SheetField("Image reference") {
            TextField("ubuntu:24.04", text: $reference)
                .accessibilityIdentifier("pullImageField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startPull() }
        }

        SheetCallout(tint: .green) {
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
        }

        SheetAdvancedSection(isExpanded: $showAdvanced) {
            PlatformPicker(title: "Platform", selection: $platformChoice)
            InsecureRegistryToggle(isOn: $allowInsecure)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        if isPulling {
            TransferProgressHeader(title: "Pulling image", progress: pullProgress)
        }

        TransferLogView(lines: pullProgress.logLines)

        if isDone {
            SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Image pulled", alignment: .center) {
                SheetCalloutDetail(text: reference)
            }
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
