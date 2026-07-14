
import SwiftUI

// MARK: - ImageDetailView

struct ImageDetailView: View {
    let imageID: String
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.images.contains(where: { $0.id == imageID }) {
            ImageDetailContent(imageID: imageID)
        } else {
            ContentUnavailableView("Image not found", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - ImageDetailContent

private struct RebuildParams: Identifiable {
    let id = UUID()
    let tag: String
    let context: BuildContext?
}

private struct ImageDetailContent: View {
    let imageID: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var errorMessage: String?
    @State private var rebuildParams: RebuildParams?
    @State private var showPushSheet = false
    @State private var showTagSheet = false
    @State private var saveRequest: ImageSaveRequest?

    private var image: ContainerImage? {
        service.images.first(where: { $0.id == imageID })
    }

    private var inspect: ImageInspectData? {
        // Keyed by content digest, not `imageID` (the local reference/name) — inspect data is
        // content-addressable, so two differently-named images sharing a digest share this too.
        image.flatMap { service.imageInspectData[$0.digest] }
    }

    var body: some View {
        if let image {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(image)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider()

                if let inspect {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            PlatformsSection(indexDigest: image.digest, variants: inspect.variants)

                            let configRows = configRows(inspect)
                            if !configRows.isEmpty {
                                InspectSection(title: "Config", rows: configRows, monoKeys: ["Command", "Work Dir"])
                            }
                            if !inspect.env.isEmpty {
                                MonoListSection(title: "Environment", items: inspect.env)
                            }
                            if !inspect.labels.isEmpty {
                                LabelsSection(labels: inspect.labels)
                            }
                            if !inspect.history.isEmpty {
                                HistorySection(history: inspect.history)
                            }
                        }
                        .padding(24)
                    }
                } else {
                    ContentUnavailableView("Details unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(item: $rebuildParams) { params in
                BuildImageSheet(
                    service: service,
                    prefillTag: params.tag,
                    prefillContext: params.context
                )
            }
            .sheet(isPresented: $showPushSheet) {
                PushImageSheet(image: image)
            }
            .sheet(isPresented: $showTagSheet) {
                TagImageSheet(image: image)
            }
            .sheet(item: $saveRequest) { request in
                SaveImageSheet(request: request)
            }
        }
    }

    private func configRows(_ d: ImageInspectData) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !d.command.isEmpty   { rows.append(("Command",     d.command)) }
        if !d.workDir.isEmpty   { rows.append(("Work Dir",    d.workDir)) }
        if !d.user.isEmpty      { rows.append(("User",        d.user)) }
        if !d.stopSignal.isEmpty { rows.append(("Stop Signal", d.stopSignal)) }
        return rows
    }

    private func detailHeader(_ image: ContainerImage) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: image.source == .built ? "hammer" : "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(image.fullName)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                // When the pane squeezes this row (detail min is 320pt), whole elements drop
                // instead of degrading in place — squeezing wraps the badges mid-word ("arm6/4")
                // and truncating leaves ellipsis soup ("18… · 2…"). Size/created go first (the
                // Platforms section still shows per-variant sizes), then the usage badge.
                ViewThatFits(in: .horizontal) {
                    metadataRow(for: image, sizeAndDate: true, usage: true)
                    metadataRow(for: image, sizeAndDate: false, usage: true)
                    metadataRow(for: image, sizeAndDate: false, usage: false)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            // Secondary actions are icon-only so the primary "Push" keeps its label without the
            // buttons + title overflowing the detail pane's width (they truncate to "Re…"
            // otherwise). Tooltips carry the names.
            if image.source == .built {
                Button {
                    rebuildParams = RebuildParams(
                        tag: image.fullName,
                        context: service.buildContext(for: image.fullName)
                    )
                } label: {
                    Label("Rebuild", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help("Rebuild")
            }

            // Tag/Save/Copy Digest share one overflow menu rather than each being an icon button —
            // a fourth control makes the header overflow at the pane's ideal width (the arch badges
            // wrap and Push loses its label; see the width comment above the Rebuild button).
            // Copy Digest also stays reachable from the Platforms section's copyable digests and
            // the list row's context menu.
            Menu {
                Button("Tag…") { showTagSheet = true }
                Button("Save to Disk…") {
                    if let destination = promptForArchiveDestination(imageName: image.fullName) {
                        saveRequest = ImageSaveRequest(reference: image.fullName, destination: destination)
                    }
                }
                Divider()
                Button("Copy Digest") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.digest, forType: .string)
                }
            } label: {
                Label("More Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Tag, save, or copy digest")

            Button {
                showPushSheet = true
            } label: {
                Label("Push", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .tint(.berthlyAccent)
            // Never give up the label: without this, the title's layoutPriority squeezes the
            // trailing button first and "Push" truncates before the (truncatable) title does.
            .fixedSize()
            .help("Push this image to a registry")
        }
    }

    /// One candidate line for the header's `ViewThatFits`. `fixedSize` on the whole row so a
    /// candidate either fits intact or is skipped — partial squeezing is what produced the
    /// mid-word badge wrap this replaces.
    private func metadataRow(for image: ContainerImage, sizeAndDate: Bool, usage: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(image.arch, id: \.self) { arch in
                Text(arch)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }
            if sizeAndDate {
                if image.sizeBytes > 0 {
                    Text(formatSize(image.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                }
                if image.created != "–" {
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(image.created).font(.caption).foregroundStyle(.secondary)
                }
            }
            if usage {
                UsageBadge(usage: image.usage)
            }
        }
        .fixedSize()
    }
}

// MARK: - Platforms Section

private struct PlatformsSection: View {
    let indexDigest: String
    let variants: [ImageVariantInfo]

    var body: some View {
        DetailSection(title: "Platforms") {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Index")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    copyableDigest(indexDigest)
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)

                ForEach(variants, id: \.digest) { variant in
                    Divider().padding(.horizontal, 16)
                    HStack {
                        HStack(spacing: 4) {
                            Text(variant.arch)
                                .font(.system(.callout, design: .monospaced, weight: .medium))
                            if let v = variant.archVariant {
                                Text(v).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 80, alignment: .leading)
                        Text(variantSize(variant.sizeBytes))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        copyableDigest(variant.digest)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func copyableDigest(_ d: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(d, forType: .string)
        } label: {
            Text(shortDigest(d))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Click to copy · \(d)")
    }

    private func shortDigest(_ d: String) -> String {
        let hex = d.hasPrefix("sha256:") ? String(d.dropFirst(7)) : d
        return "sha256:\(hex.prefix(12))…"
    }

    private func variantSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1    { return String(format: "%.0f MB", mb) }
        return "<1 MB"
    }
}

// MARK: - Generic key/value rows

private struct InspectSection: View {
    let title: LocalizedStringKey
    let rows: [(String, String)]
    let monoKeys: [String]

    var body: some View {
        DetailSection(title: title) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, pair in
                    HStack(alignment: .top, spacing: 0) {
                        Text(pair.0)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(pair.1)
                            .fontDesign(monoKeys.contains(pair.0) ? .monospaced : .default)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    if idx < rows.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Mono list (env vars)

private struct MonoListSection: View {
    let title: LocalizedStringKey
    let items: [String]

    var body: some View {
        DetailSection(title: title) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack {
                        Text(item)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    if idx < items.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Labels

private struct LabelsSection: View {
    let labels: [String: String]
    private var sorted: [(String, String)] { labels.sorted { $0.key < $1.key } }

    var body: some View {
        DetailSection(title: "Labels") {
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { idx, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text(pair.1).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    if idx < sorted.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - History

private struct HistorySection: View {
    let history: [String]

    var body: some View {
        DetailSection(title: "History") {
            VStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    if idx < history.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Preview

#Preview {
    let mock = MockContainerService()
    ImageDetailView(imageID: mock.images[0].id)
        .environment(mock as ContainerServiceBase)
        .frame(width: 480, height: 700)
}

#Preview("Pulled image – no inspect data") {
    let mock = MockContainerService()
    ImageDetailView(imageID: mock.images[4].id)
        .environment(mock as ContainerServiceBase)
        .frame(width: 480, height: 700)
}
