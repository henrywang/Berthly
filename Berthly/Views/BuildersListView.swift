import SwiftUI

struct SystemView: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                builderSection
            }
            .padding(20)
        }
        .navigationTitle("System")
    }

    @ViewBuilder
    private var builderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUILDER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            if service.builders.isEmpty {
                Text("No builder found. Create one with `container builder create`.")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            } else {
                ForEach(service.builders) { builder in
                    BuilderCard(builder: builder)
                }
            }
        }
    }
}

// MARK: - Builder Card

private struct BuilderCard: View {
    let builder: Builder
    @Environment(ContainerServiceBase.self) private var service
    @State private var showStopConfirm = false
    @State private var isStopping = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header row: icon + name + status badge + stop button
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "hammer")
                    .foregroundStyle(builder.status == .running ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                    .imageScale(.medium)

                Text(builder.name)
                    .font(.system(.body, design: .default, weight: .semibold))

                StatusBadge(status: builder.status == .running ? .running : .stopped)

                Spacer()

                if builder.status == .running {
                    Button(role: .destructive) { showStopConfirm = true } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .tint(.statusError)
                    .disabled(isStopping)
                    .help("Stop Builder")
                }
            }

            Divider()

            // Info grid
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    infoLabel("Image")
                    Text(builder.image)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GridRow {
                    infoLabel("Resources")
                    Text("\(builder.cpus) vCPU · \(builder.memoryGB) GB")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if builder.autoStarted {
                    GridRow {
                        infoLabel("Mode")
                        Text("Auto-start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .opacity(isStopping ? 0.4 : 1)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .alert("Stop \(builder.name)?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) {
                isStopping = true
                Task {
                    do { try await service.stopBuilder(builder.id) }
                    catch { errorMessage = error.localizedDescription }
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The builder container will be shut down.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func infoLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(minWidth: 64, alignment: .leading)
    }
}

#Preview {
    SystemView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 360, height: 300)
}
