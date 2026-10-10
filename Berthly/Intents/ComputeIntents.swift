// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppIntents

/// What each intent does, apart from the App Intents plumbing. `@Parameter`/`@Dependency` assert
/// when touched outside the system's intent runtime, so tests cover the behavior here instead of
/// calling `perform()`.
enum ComputeIntentActions {
    @MainActor
    static func start(_ item: ComputeItem, in service: ContainerServiceBase) async throws {
        switch item {
        case .container(let id): try await service.startContainer(id)
        case .machine(let id): try await service.startMachine(id)
        }
    }

    @MainActor
    static func stop(_ item: ComputeItem, in service: ContainerServiceBase) async throws {
        switch item {
        case .container(let id): try await service.stopContainer(id)
        case .machine(let id): try await service.stopMachine(id)
        }
    }

    @MainActor
    static func open(_ item: ComputeItem, in bridge: MenuBarBridge) {
        bridge.pendingIntent = .selectCompute(item)
    }
}

struct StartContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Container"
    static let description = IntentDescription("Starts a stopped container.")
    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$container)") }

    @Parameter(title: "Container") var container: ContainerEntity
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ComputeIntentActions.start(.container(container.id), in: service)
        return .result()
    }
}

struct StopContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Container"
    static let description = IntentDescription("Stops a running container.")
    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$container)") }

    @Parameter(title: "Container") var container: ContainerEntity
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ComputeIntentActions.stop(.container(container.id), in: service)
        return .result()
    }
}

struct OpenContainerIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Container"
    static let description = IntentDescription("Shows a container in Berthly.")

    @Parameter(title: "Container") var target: ContainerEntity
    @Dependency private var bridge: MenuBarBridge

    @MainActor
    func perform() async throws -> some IntentResult {
        ComputeIntentActions.open(.container(target.id), in: bridge)
        return .result()
    }
}

struct StartMachineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Machine"
    static let description = IntentDescription("Starts a stopped machine.")
    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$machine)") }

    @Parameter(title: "Machine") var machine: MachineEntity
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ComputeIntentActions.start(.machine(machine.id), in: service)
        return .result()
    }
}

struct StopMachineIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Machine"
    static let description = IntentDescription("Stops a running machine.")
    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$machine)") }

    @Parameter(title: "Machine") var machine: MachineEntity
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ComputeIntentActions.stop(.machine(machine.id), in: service)
        return .result()
    }
}

struct OpenMachineIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Machine"
    static let description = IntentDescription("Shows a machine in Berthly.")

    @Parameter(title: "Machine") var target: MachineEntity
    @Dependency private var bridge: MenuBarBridge

    @MainActor
    func perform() async throws -> some IntentResult {
        ComputeIntentActions.open(.machine(target.id), in: bridge)
        return .result()
    }
}
