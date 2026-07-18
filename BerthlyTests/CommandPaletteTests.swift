// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

// MARK: - Ranking (pure, nonisolated)

@Suite struct CommandPaletteRankingTests {

    /// A minimal command whose only interesting fields are what the matcher reads.
    private func cmd(_ id: String, _ title: String, subtitle: String? = nil, keywords: [String] = []) -> PaletteCommand {
        PaletteCommand(id: id, title: title, subtitle: subtitle, systemImage: "circle", keywords: keywords, action: .refresh)
    }

    @Test func emptyQueryReturnsAllInOriginalOrder() {
        let commands = [cmd("a", "Alpha"), cmd("b", "Beta"), cmd("c", "Gamma")]
        let ranked = rankedPaletteCommands(commands, query: "")
        #expect(ranked.map(\.id) == ["a", "b", "c"])
    }

    @Test func whitespaceOnlyQueryIsTreatedAsEmpty() {
        let commands = [cmd("a", "Alpha"), cmd("b", "Beta")]
        #expect(rankedPaletteCommands(commands, query: "   ").map(\.id) == ["a", "b"])
    }

    @Test func exactTitleMatchRanksFirst() {
        let commands = [
            cmd("prefix", "Runner"),      // "run" is a prefix
            cmd("exact", "Run"),          // exact
            cmd("substr", "Prerun task") // "run" is a substring mid-string
        ]
        let ranked = rankedPaletteCommands(commands, query: "run")
        #expect(ranked.first?.id == "exact")
    }

    @Test func prefixBeatsSubstringBeatsSubsequence() {
        let commands = [
            cmd("sub", "docker-nginx"),   // "dn" is a subsequence
            cmd("substr", "abc-dn-xyz"),  // "dn" is a contiguous substring
            cmd("pre", "dns settings")   // "dn" is a prefix
        ]
        let ranked = rankedPaletteCommands(commands, query: "dn")
        #expect(ranked.map(\.id) == ["pre", "substr", "sub"])
    }

    @Test func matchingIsCaseInsensitive() {
        let ranked = rankedPaletteCommands([cmd("a", "Build Image…")], query: "BUILD")
        #expect(ranked.map(\.id) == ["a"])
    }

    @Test func nonMatchingCommandsAreDropped() {
        let commands = [cmd("a", "Run Container"), cmd("b", "Pull Image")]
        let ranked = rankedPaletteCommands(commands, query: "volume")
        #expect(ranked.isEmpty)
    }

    @Test func keywordMatchesButRanksBelowTitleMatch() {
        let commands = [
            cmd("kw", "Add Registry…", keywords: ["login"]), // matches only via keyword
            cmd("title", "Login window")                    // matches in the title
        ]
        let ranked = rankedPaletteCommands(commands, query: "login")
        #expect(ranked.map(\.id) == ["title", "kw"])
    }

    @Test func subtitleIsSearchable() {
        // A container command's subtitle is its image; typing the image should surface it.
        let commands = [cmd("c", "Open web-frontend", subtitle: "local/web:1.4")]
        let ranked = rankedPaletteCommands(commands, query: "local/web")
        #expect(ranked.map(\.id) == ["c"])
    }

    @Test func fuzzySubsequenceMatches() {
        #expect(isSubsequence("dcn", of: "docker-nginx"))
        #expect(!isSubsequence("dnc", of: "docker-nginx")) // out of order
        #expect(isSubsequence("", of: "anything"))
    }
}

// MARK: - Command construction (MainActor — reads model structs)

@MainActor
@Suite struct CommandPaletteBuildTests {

    private func container(_ id: String, _ name: String, status: ContainerStatus, image: String = "img:1") -> Container {
        Container(id: id, name: name, image: image, status: status, ports: [], cpuPercent: 0, memoryMB: 0,
                  memoryLimitMB: 0, networkIOString: "–", uptime: "–", command: "", mounts: [], networks: [], environment: [])
    }

    private func machine(_ id: String, _ name: String, status: ContainerStatus, isUtility: Bool = false) -> Machine {
        Machine(id: id, name: name, image: "img", status: status, isUtility: isUtility, diskUsedGB: 0, diskTotalGB: 0,
                uptimeString: "–", kernel: "", resources: "", created: "", homeMount: .none)
    }

    @Test func disconnectedOffersOnlyNavigation() {
        let commands = buildPaletteCommands(isConnected: false, containers: [container("c1", "web", status: .running)], machines: [])
        #expect(commands.allSatisfy { if case .navigate = $0.action { return true } else { return false } })
        #expect(commands.contains { $0.action == .navigate(.compute) })
    }

    @Test func connectedIncludesGlobalActions() {
        let commands = buildPaletteCommands(isConnected: true, containers: [], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.runContainer))
        #expect(actions.contains(.buildImage))
        #expect(actions.contains(.pullImage))
        #expect(actions.contains(.refresh))
    }

    @Test func runningContainerGetsStopAndRestartNotStart() {
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "web", status: .running)], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.stopContainer("c1")))
        #expect(actions.contains(.restartContainer("c1")))
        #expect(actions.contains(.selectContainer("c1")))
        #expect(!actions.contains(.startContainer("c1")))
    }

    @Test func stoppedContainerGetsStartNotStop() {
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "worker", status: .stopped)], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.startContainer("c1")))
        #expect(!actions.contains(.stopContainer("c1")))
        #expect(!actions.contains(.restartContainer("c1")))
    }

    @Test func utilityMachinesAreExcluded() {
        let commands = buildPaletteCommands(
            isConnected: true, containers: [],
            machines: [machine("m1", "dev", status: .running), machine("util", "default", status: .running, isUtility: true)])
        let actions = commands.map(\.action)
        #expect(actions.contains(.selectMachine("m1")))
        #expect(!actions.contains(.selectMachine("util")))
        #expect(!actions.contains(.stopMachine("util")))
    }

    @Test func runningContainerOffersShellNotDelete() {
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "web", status: .running)], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.openContainerShell("c1")))
        #expect(!actions.contains(.deleteContainer("c1")))
    }

    @Test func stoppedContainerOffersDeleteNotShell() {
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "worker", status: .stopped)], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.deleteContainer("c1")))
        #expect(!actions.contains(.openContainerShell("c1")))
    }

    @Test func pausedContainerOffersDeleteNotShell() {
        // Terminal needs a running container, but delete is disabled only while running — so a
        // paused container gets Delete but not Open Shell.
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "sandbox", status: .paused)], machines: [])
        let actions = commands.map(\.action)
        #expect(actions.contains(.deleteContainer("c1")))
        #expect(!actions.contains(.openContainerShell("c1")))
    }

    @Test func runningMachineOffersShellNotDelete() {
        let commands = buildPaletteCommands(isConnected: true, containers: [], machines: [machine("m1", "dev", status: .running)])
        let actions = commands.map(\.action)
        #expect(actions.contains(.openMachineShell("m1")))
        #expect(!actions.contains(.deleteMachine("m1")))
    }

    @Test func stoppedMachineOffersDeleteNotShell() {
        let commands = buildPaletteCommands(isConnected: true, containers: [], machines: [machine("m1", "ci", status: .stopped)])
        let actions = commands.map(\.action)
        #expect(actions.contains(.deleteMachine("m1")))
        #expect(!actions.contains(.openMachineShell("m1")))
    }

    @Test func containerImageIsSearchableViaSubtitleAndKeywords() {
        let commands = buildPaletteCommands(isConnected: true, containers: [container("c1", "web", status: .running, image: "nginx:latest")], machines: [])
        let ranked = rankedPaletteCommands(commands, query: "nginx")
        #expect(ranked.contains { $0.action == .selectContainer("c1") })
    }
}
