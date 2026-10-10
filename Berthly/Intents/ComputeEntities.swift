// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppIntents
import CoreSpotlight

/// A container as Shortcuts, Siri and Spotlight see it. Carries display strings only; actions go
/// back through the service by `id`, so a stale entity can never act on stale state.
struct ContainerEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Container")
    static let defaultQuery = ContainerEntityQuery()

    let id: String
    let name: String
    let image: String
    let status: String

    init(_ container: Container) {
        id = container.id
        name = container.name
        image = container.image
        status = container.status.label
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(image) · \(status)",
            image: .init(systemName: "shippingbox"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = "\(image) · \(status)"
        attributes.keywords = ["container", image]
        return attributes
    }
}

struct MachineEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Machine")
    static let defaultQuery = MachineEntityQuery()

    let id: String
    let name: String
    let image: String
    let status: String

    init(_ machine: Machine) {
        id = machine.id
        name = machine.name
        image = machine.image
        status = machine.status.label
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(image) · \(status)",
            image: .init(systemName: "desktopcomputer"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = "\(image) · \(status)"
        attributes.keywords = ["machine", "virtual machine", image]
        return attributes
    }
}

/// Lookup rules shared by the queries and the tests. Utility machines (the internal default VM)
/// are excluded for the same reason the sidebar hides them: they are runtime plumbing, not
/// something a user starts or stops by name.
enum ComputeEntityCatalog {
    @MainActor
    static func containers(in service: ContainerServiceBase, ids: [String]? = nil, matching text: String? = nil) -> [ContainerEntity] {
        service.containers
            .filter { ids?.contains($0.id) ?? true }
            .filter { matches(text, $0.name, $0.image) }
            .map(ContainerEntity.init)
    }

    @MainActor
    static func machines(in service: ContainerServiceBase, ids: [String]? = nil, matching text: String? = nil) -> [MachineEntity] {
        service.machines
            .filter { !$0.isUtility }
            .filter { ids?.contains($0.id) ?? true }
            .filter { matches(text, $0.name, $0.image) }
            .map(MachineEntity.init)
    }

    private static func matches(_ text: String?, _ fields: String...) -> Bool {
        guard let text, !text.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

struct ContainerEntityQuery: EntityStringQuery {
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        ComputeEntityCatalog.containers(in: service, ids: identifiers)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ContainerEntity] {
        ComputeEntityCatalog.containers(in: service, matching: string)
    }

    @MainActor
    func suggestedEntities() async throws -> [ContainerEntity] {
        ComputeEntityCatalog.containers(in: service)
    }
}

struct MachineEntityQuery: EntityStringQuery {
    @Dependency private var service: ContainerServiceBase

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MachineEntity] {
        ComputeEntityCatalog.machines(in: service, ids: identifiers)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MachineEntity] {
        ComputeEntityCatalog.machines(in: service, matching: string)
    }

    @MainActor
    func suggestedEntities() async throws -> [MachineEntity] {
        ComputeEntityCatalog.machines(in: service)
    }
}
