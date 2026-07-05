import SwiftUI

enum SidebarSelection: Hashable {
    case compute
    case volumes
    case networks
    case images
    case registries
    case system
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        List(selection: $selection) {
            Section("COMPUTE") {
                SidebarRow(icon: "shippingbox", label: "Compute", badge: runningComputeCount)
                    .tag(SidebarSelection.compute)
            }

            Section("LIBRARY") {
                SidebarRow(icon: "cylinder",              label: "Volumes",    badge: service.volumes.count)
                    .tag(SidebarSelection.volumes)
                SidebarRow(icon: "arrow.triangle.branch", label: "Networks",   badge: service.networks.count)
                    .tag(SidebarSelection.networks)
                SidebarRow(icon: "square.stack.3d.up",   label: "Images",     badge: service.images.count)
                    .tag(SidebarSelection.images)
                SidebarRow(icon: "building.columns",      label: "Registries", badge: service.registries.count)
                    .tag(SidebarSelection.registries)
            }

            Section("SYSTEM") {
                SidebarRow(icon: "gearshape", label: "System")
                    .tag(SidebarSelection.system)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DaemonStatusBar(state: service.daemonState, warning: service.lastStartupWarning)
        }
    }

    private var runningComputeCount: Int {
        service.containers.filter { $0.status == .running }.count +
        service.machines.filter { $0.status == .running && !$0.isUtility }.count
    }

}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let icon: String
    let label: String
    var badge: Int? = nil
    var badgeText: String? = nil
    var indent: Bool = false

    var body: some View {
        Label(label, systemImage: icon)
            .padding(.leading, indent ? 16 : 0)
            .badge(badgeText ?? (badge.map { "\($0)" } ?? ""))
    }
}

// MARK: - Daemon Status Bar

struct DaemonStatusBar: View {
    let state: DaemonState
    /// Non-nil when the daemon connected fine but a background bootstrap step
    /// (vminit image / default kernel install) failed. Only shown while `.connected`.
    var warning: String? = nil

    var body: some View {
        HStack {
            Text("Container Daemon")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .imageScale(.small)
            Text(statusWord)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .help(activeWarning ?? "")
    }

    private var activeWarning: String? {
        guard case .connected = state else { return nil }
        return warning
    }

    private var statusIcon: String {
        if activeWarning != nil { return "exclamationmark.triangle.fill" }
        return switch state {
        case .connected:           "circle.fill"
        case .connecting:          "circle.dotted"
        case .stopping:            "circle.dotted"
        case .notInstalled:        "xmark.circle"
        case .installedButStopped: "circle"
        case .versionMismatch:     "exclamationmark.triangle"
        case .error:               "exclamationmark.circle"
        case .checking:            "circle.dotted"
        }
    }

    private var statusColor: Color {
        if activeWarning != nil { return .statusPaused }
        return switch state {
        case .connected:  .statusRunning
        case .error:      .statusError
        default:          Color(NSColor.tertiaryLabelColor)
        }
    }

    private var statusWord: String {
        if activeWarning != nil { return "Running (warning)" }
        return switch state {
        case .connected:                   "Running"
        case .connecting:                  "Connecting…"
        case .stopping:                    "Stopping…"
        case .notInstalled:                "Not installed"
        case .installedButStopped:         "Stopped"
        case .versionMismatch(let v, _):   "v\(v) mismatch"
        case .error:                       "Error"
        case .checking:                    "Checking…"
        }
    }
}

#Preview {
    SidebarView(selection: .constant(.compute))
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 220, height: 500)
}
