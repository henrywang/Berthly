// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Observation
import TerminalProgress

/// Observable base class for the container service layer.
/// Inject via .environment(service as ContainerServiceBase).
/// Access in views via @Environment(ContainerServiceBase.self).
@Observable
@MainActor
class ContainerServiceBase {
    var daemonState: DaemonState = .checking
    var containers: [Container] = []
    var images: [ContainerImage] = []
    var imageInspectData: [String: ImageInspectData] = [:]
    var volumes: [Volume] = []
    var networks: [Network] = []
    var machines: [Machine] = []
    var builders: [Builder] = []
    var registries: [Registry] = []
    var buildContexts: [String: BuildContext] = [:]

    /// Set when `startDaemon()` connects fine but a background bootstrap step (installing the
    /// vminit filesystem image or default kernel) failed — the daemon reports `.connected`
    /// regardless (it's the correct state for most purposes), so without this the failure is
    /// otherwise invisible until an unrelated later operation fails for a confusing reason.
    /// `nil` means no warning; cleared at the start of every `startDaemon()` call.
    var lastStartupWarning: String? = nil

    func buildContext(for reference: String) -> BuildContext? { buildContexts[reference] }
    func saveBuildContext(_ ctx: BuildContext, for reference: String) { buildContexts[reference] = ctx }
    func buildImage(options: BuildOptions, onLog: @MainActor @escaping (String) -> Void) async throws {}
    @discardableResult
    func runContainer(options: RunOptions) async throws -> String { "" }
    func createMachine(options: MachineCreateOptions) async throws {}

    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String) async throws {}
    func restartContainer(_ id: String) async throws {}
    func deleteContainer(_ id: String) async throws {}
    func startMachine(_ id: String) async throws {}
    func stopMachine(_ id: String) async throws {}
    func deleteMachine(_ id: String) async throws {}
    func deleteImage(_ reference: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func deleteNetwork(_ id: String) async throws {}
    func stopBuilder(_ id: String) async throws {}
    func pullImage(reference: String, platform: String? = nil, insecure: Bool = false, progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {}
    func startDaemon() async {}
    func refresh() async {}

    var isConnected: Bool {
        if case .connected = daemonState { return true }
        return false
    }
}
