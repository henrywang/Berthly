// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Where a "navigate" command should send the sidebar. A palette-local mirror of
/// `SidebarSelection` (which lives in the view layer and isn't `nonisolated`): keeping this a
/// standalone `nonisolated` enum lets `PaletteAction`/`PaletteCommand` stay pure value types the
/// matcher and its tests can touch off the main actor. `MainWindowView` maps it back.
nonisolated enum PaletteSection: Equatable {
    case compute, volumes, networks, images, registries, system
}

/// A single thing the command palette can do. All payloads are primitives (ids, enums) so the
/// whole action type is `nonisolated` and `Equatable` — the view layer maps each case onto the
/// existing sheet/intent/service plumbing in `MainWindowView.dispatch(_:)`.
///
/// v1 is deliberately restricted to safe, reversible actions: navigation, the create/run/build/pull
/// sheets, object-select, and start/stop/restart. Destructive actions (delete) and "open shell"
/// are intentionally absent — delete needs its existing confirmation dialog and shell needs
/// detail-tab routing that doesn't exist yet; both are clean follow-ons.
nonisolated enum PaletteAction: Equatable {
    case navigate(PaletteSection)

    case runContainer
    case createMachine
    case buildImage
    case pullImage
    case createVolume
    case createNetwork
    case addRegistry
    case refresh

    case selectContainer(String)
    case selectMachine(String)
    case startContainer(String)
    case stopContainer(String)
    case restartContainer(String)
    case startMachine(String)
    case stopMachine(String)
}

/// One row in the palette. `keywords` are extra match terms not shown in the UI (e.g. an image
/// name, or synonyms) so typing "ubuntu" can surface a container running that image.
nonisolated struct PaletteCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let keywords: [String]
    let action: PaletteAction

    init(id: String, title: String, subtitle: String? = nil, systemImage: String, keywords: [String] = [], action: PaletteAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.keywords = keywords
        self.action = action
    }
}

// MARK: - Matching / ranking

/// Score a single candidate string against an already-lowercased query. Higher is better; `nil`
/// means no match at all. The tiers rank the ways a match can happen, best first: exact equality,
/// prefix, contiguous substring (earlier position scores higher), then a loose subsequence match
/// (all query characters appear in order, allowing gaps — the "fuzzy" case). `candidate` is
/// assumed already lowercased by the caller.
nonisolated func paletteCandidateScore(_ candidate: String, lowercasedQuery query: String) -> Int? {
    if query.isEmpty { return 0 }
    if candidate == query { return 1000 }
    if candidate.hasPrefix(query) { return 900 }
    if let range = candidate.range(of: query) {
        let position = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        return 700 - min(position, 100)
    }
    return isSubsequence(query, of: candidate) ? 400 : nil
}

/// True if every character of `needle` appears in `haystack` in order (gaps allowed). Both are
/// assumed already lowercased. This is the fuzzy fallback — "dcn" matches "docker-nginx".
nonisolated func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    guard !needle.isEmpty else { return true }
    var ni = needle.startIndex
    for ch in haystack where ch == needle[ni] {
        ni = needle.index(after: ni)
        if ni == needle.endIndex { return true }
    }
    return false
}

/// A command's overall score: the best of its title match and its (discounted) subtitle/keyword
/// matches, so a title hit always outranks an equivalent keyword hit. `nil` if nothing matches.
nonisolated func paletteCommandScore(_ command: PaletteCommand, lowercasedQuery query: String) -> Int? {
    var best = paletteCandidateScore(command.title.lowercased(), lowercasedQuery: query)
    let secondary = [command.subtitle].compactMap { $0 } + command.keywords
    for term in secondary {
        if let s = paletteCandidateScore(term.lowercased(), lowercasedQuery: query) {
            // Discount so a title match beats an equal-tier keyword match, but a strong keyword
            // match (exact) can still beat a weak title match (loose subsequence).
            let discounted = s - 150
            if best == nil || discounted > best! { best = discounted }
        }
    }
    return best
}

/// Filter and rank `commands` for `query`. An empty/whitespace query returns every command in the
/// original (grouped) order — the palette doubles as a discoverable command list before typing.
/// Otherwise, only matching commands are returned, best score first; ties preserve input order
/// (a stable sort, since Swift's `sorted` isn't stable on its own).
nonisolated func rankedPaletteCommands(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return commands }

    return commands.enumerated()
        .compactMap { index, command -> (Int, Int, PaletteCommand)? in
            guard let score = paletteCommandScore(command, lowercasedQuery: trimmed) else { return nil }
            return (score, index, command)
        }
        .sorted { lhs, rhs in
            lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
        }
        .map(\.2)
}

// MARK: - Command construction

/// Build the full palette command set from the current app state. MainActor because it reads the
/// model structs (`Container`/`Machine`), which are MainActor-isolated in this module. Ordering is
/// meaningful: it's the order shown for an empty query (navigation, then global actions, then
/// per-object actions), and the stable tiebreak for equal scores.
///
/// When disconnected, only navigation is offered — every other action needs a live daemon.
@MainActor
func buildPaletteCommands(isConnected: Bool, containers: [Container], machines: [Machine]) -> [PaletteCommand] {
    var commands: [PaletteCommand] = [
        PaletteCommand(id: "nav.compute", title: "Go to Compute", systemImage: "shippingbox",
                       keywords: ["containers", "machines"], action: .navigate(.compute)),
        PaletteCommand(id: "nav.images", title: "Go to Images", systemImage: "square.stack.3d.up",
                       action: .navigate(.images)),
        PaletteCommand(id: "nav.volumes", title: "Go to Volumes", systemImage: "cylinder",
                       action: .navigate(.volumes)),
        PaletteCommand(id: "nav.networks", title: "Go to Networks", systemImage: "arrow.triangle.branch",
                       action: .navigate(.networks)),
        PaletteCommand(id: "nav.registries", title: "Go to Registries", systemImage: "person.crop.circle",
                       action: .navigate(.registries)),
        PaletteCommand(id: "nav.system", title: "Go to System", systemImage: "gearshape.2",
                       action: .navigate(.system)),
    ]

    guard isConnected else { return commands }

    commands += [
        PaletteCommand(id: "action.run", title: "Run Container…", systemImage: "play.fill",
                       keywords: ["new", "start", "create"], action: .runContainer),
        PaletteCommand(id: "action.createMachine", title: "Create Machine…", systemImage: "desktopcomputer",
                       keywords: ["vm", "new"], action: .createMachine),
        PaletteCommand(id: "action.build", title: "Build Image…", systemImage: "hammer",
                       keywords: ["dockerfile"], action: .buildImage),
        PaletteCommand(id: "action.pull", title: "Pull Image…", systemImage: "arrow.down.circle",
                       keywords: ["download", "registry"], action: .pullImage),
        PaletteCommand(id: "action.createVolume", title: "Create Volume…", systemImage: "cylinder",
                       keywords: ["new"], action: .createVolume),
        PaletteCommand(id: "action.createNetwork", title: "Create Network…", systemImage: "arrow.triangle.branch",
                       keywords: ["new"], action: .createNetwork),
        PaletteCommand(id: "action.addRegistry", title: "Add Registry…", systemImage: "plus.circle",
                       keywords: ["login", "sign in"], action: .addRegistry),
        PaletteCommand(id: "action.refresh", title: "Refresh", systemImage: "arrow.clockwise",
                       keywords: ["reload"], action: .refresh),
    ]

    for container in containers {
        let name = container.name
        commands.append(PaletteCommand(
            id: "container.select.\(container.id)", title: "Open \(name)",
            subtitle: container.image, systemImage: "shippingbox", keywords: [container.image, "container"],
            action: .selectContainer(container.id)))

        switch container.status {
        case .running, .paused:
            commands.append(PaletteCommand(
                id: "container.stop.\(container.id)", title: "Stop \(name)",
                subtitle: container.image, systemImage: "stop.fill", keywords: ["container"],
                action: .stopContainer(container.id)))
            commands.append(PaletteCommand(
                id: "container.restart.\(container.id)", title: "Restart \(name)",
                subtitle: container.image, systemImage: "arrow.clockwise.circle", keywords: ["container"],
                action: .restartContainer(container.id)))
        case .stopped, .error:
            commands.append(PaletteCommand(
                id: "container.start.\(container.id)", title: "Start \(name)",
                subtitle: container.image, systemImage: "play.fill", keywords: ["container"],
                action: .startContainer(container.id)))
        }
    }

    for machine in machines where !machine.isUtility {
        let name = machine.name
        commands.append(PaletteCommand(
            id: "machine.select.\(machine.id)", title: "Open \(name)",
            subtitle: "machine", systemImage: "desktopcomputer", keywords: ["machine", "vm"],
            action: .selectMachine(machine.id)))

        switch machine.status {
        case .running, .paused:
            commands.append(PaletteCommand(
                id: "machine.stop.\(machine.id)", title: "Stop \(name)",
                subtitle: "machine", systemImage: "stop.fill", keywords: ["machine", "vm"],
                action: .stopMachine(machine.id)))
        case .stopped, .error:
            commands.append(PaletteCommand(
                id: "machine.start.\(machine.id)", title: "Start \(name)",
                subtitle: "machine", systemImage: "play.fill", keywords: ["machine", "vm"],
                action: .startMachine(machine.id)))
        }
    }

    return commands
}
