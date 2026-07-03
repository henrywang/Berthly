//
//  BerthlyTests.swift
//  BerthlyTests
//
//  Created by Henry Wang on 6/28/26.
//

import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Testing
@testable import Berthly

// MARK: - BuildContext Codable

struct BuildContextCodableTests {

    @Test func roundTripPreservesAllFields() throws {
        let original = BuildContext(
            contextPath: "/Users/dev/web",
            dockerfilePath: "Containerfile",
            platform: "linux/arm64",
            buildArgs: ["NODE_ENV": "production"],
            labels: ["team": "web"],
            target: "release",
            noCache: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BuildContext.self, from: data)
        #expect(decoded == original)
    }

    @Test func decodingLegacyJSONMissingNewFieldsFillsDefaults() throws {
        // Shape saved to disk before buildArgs/labels/target/noCache/platform existed.
        let legacyJSON = """
        {"contextPath":"/Users/dev/web","dockerfilePath":"Containerfile"}
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(BuildContext.self, from: data)

        #expect(decoded.contextPath == "/Users/dev/web")
        #expect(decoded.dockerfilePath == "Containerfile")
        #expect(decoded.platform == nil)
        #expect(decoded.buildArgs.isEmpty)
        #expect(decoded.labels.isEmpty)
        #expect(decoded.target == nil)
        #expect(decoded.noCache == false)
    }

    @Test func decodingLegacyDictionaryOfContextsStillWorks() throws {
        let legacyJSON = """
        {"local/web:1.4":{"contextPath":"/Users/dev/web","dockerfilePath":null}}
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode([String: BuildContext].self, from: data)
        #expect(decoded["local/web:1.4"]?.contextPath == "/Users/dev/web")
    }
}

// MARK: - LiveContainerService build*/resolve* (pure BuildOptions -> native-API mapping)
//
// `buildImage` now drives the vendored package's own gRPC `Builder` client natively instead of
// shelling out to `container build`, so what used to be CLI-argument-array construction is now
// pure Dockerfile-path/secret/tag/platform resolution.

struct BuildMappingTests {

    @Test func resolveDockerfilePathUsesExplicitPathWhenGiven() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dockerfile = tmp.appendingPathComponent("Custom.dockerfile")
        try Data().write(to: dockerfile)

        let options = BuildOptions(reference: "local/web:1.0", contextPath: tmp.path, dockerfilePath: dockerfile.path)
        #expect(try LiveContainerService.resolveDockerfilePath(for: options) == dockerfile.path)
    }

    @Test func resolveDockerfilePathFallsBackToContextDirDockerfile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dockerfile = tmp.appendingPathComponent("Dockerfile")
        try Data().write(to: dockerfile)

        let options = BuildOptions(reference: "local/web:1.0", contextPath: tmp.path)
        #expect(try LiveContainerService.resolveDockerfilePath(for: options) == dockerfile.path)
    }

    @Test func resolveDockerfilePathThrowsWhenNothingFound() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let options = BuildOptions(reference: "local/web:1.0", contextPath: tmp.path)
        #expect(throws: (any Error).self) {
            try LiveContainerService.resolveDockerfilePath(for: options)
        }
    }

    @Test func resolveBuildSecretsReadsFromEnvironmentVariable() throws {
        setenv("BERTHLY_TEST_SECRET", "shh", 1)
        defer { unsetenv("BERTHLY_TEST_SECRET") }
        let secrets = try LiveContainerService.resolveBuildSecrets(["id=mysecret,env=BERTHLY_TEST_SECRET"])
        #expect(secrets["mysecret"] == Data("shh".utf8))
    }

    @Test func resolveBuildSecretsReadsFromFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("filesecret".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let secrets = try LiveContainerService.resolveBuildSecrets(["id=mysecret,src=\(tmp.path)"])
        #expect(secrets["mysecret"] == Data("filesecret".utf8))
    }

    @Test func resolveBuildSecretsRejectsMissingIdPrefix() {
        #expect(throws: (any Error).self) {
            try LiveContainerService.resolveBuildSecrets(["mysecret,env=FOO"])
        }
    }

    @Test func buildTagsNormalizesReference() throws {
        let options = BuildOptions(reference: "local/web:1.0", contextPath: "/tmp/web")
        let tags = try LiveContainerService.buildTags(for: options)
        #expect(tags == ["local/web:1.0"])
    }

    @Test func buildTagsGeneratesRandomTagWhenReferenceEmpty() throws {
        let options = BuildOptions(reference: "", contextPath: "/tmp/web")
        let tags = try LiveContainerService.buildTags(for: options)
        #expect(tags.count == 1)
        #expect(!tags[0].isEmpty)
    }

    @Test func buildPlatformsParsesExplicitPlatform() throws {
        let options = BuildOptions(reference: "local/web:1.0", contextPath: "/tmp/web", platform: "linux/arm64")
        let platforms = try LiveContainerService.buildPlatforms(for: options)
        #expect(platforms.map(\.description) == ["linux/arm64/v8"])
    }

    @Test func buildPlatformsDefaultsToHostLinuxPlatformWhenUnset() throws {
        let options = BuildOptions(reference: "local/web:1.0", contextPath: "/tmp/web")
        let platforms = try LiveContainerService.buildPlatforms(for: options)
        #expect(platforms.count == 1)
        #expect(platforms[0].os == "linux")
    }
}

// MARK: - LiveContainerService run*Flags (pure RunOptions -> Flags.* mapping)
//
// `runContainer` now calls the vendored package's own `Utility.containerConfigFromFlags`
// natively (XPC API) instead of shelling out to the `container` CLI, so what used to be pure
// CLI-argument-array construction is now pure `Flags.*` struct construction. These tests assert
// on the resulting struct fields directly since `Flags.*` types aren't Equatable.

struct RunFlagsMappingTests {

    @Test func processFlagsMapWorkdirUserTtyAndInteractive() {
        let options = RunOptions(
            reference: "local/web:1.0",
            workdir: "/app",
            user: "1000:1000",
            interactive: true,
            tty: true
        )
        let flags = LiveContainerService.runProcessFlags(for: options)
        #expect(flags.cwd == "/app")
        #expect(flags.user == "1000:1000")
        #expect(flags.interactive == true)
        #expect(flags.tty == true)
    }

    @Test func processFlagsSortEnvAndOmitEmptyStrings() {
        let options = RunOptions(
            reference: "local/web:1.0",
            env: ["NODE_ENV": "production", "DEBUG": "1"],
            workdir: "",
            user: ""
        )
        let flags = LiveContainerService.runProcessFlags(for: options)
        #expect(flags.env == ["DEBUG=1", "NODE_ENV=production"])
        #expect(flags.cwd == nil)
        #expect(flags.user == nil)
    }

    @Test func managementFlagsMapNameRemovePortsVolumesAndLabels() {
        let options = RunOptions(
            reference: "local/web:1.0",
            name: "web-1",
            ports: ["8080:80", "9000:9000/udp"],
            volumes: ["data:/var/lib/data"],
            remove: true,
            labels: ["team": "web"]
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        #expect(flags.name == "web-1")
        #expect(flags.remove == true)
        #expect(flags.publishPorts == ["8080:80", "9000:9000/udp"])
        #expect(flags.volumes == ["data:/var/lib/data"])
        #expect(flags.labels == ["team=web"])
    }

    @Test func managementFlagsMapAdvancedFields() {
        let options = RunOptions(
            reference: "local/web:1.0",
            platform: "linux/arm64",
            networks: ["app-net"],
            entrypoint: "/bin/sh",
            readOnly: true,
            initProcess: true,
            rosetta: true,
            ssh: true,
            shmSize: "64m",
            tmpfs: ["/tmp/scratch"],
            insecureRegistry: true
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        let registry = LiveContainerService.runRegistryFlags(for: options)
        #expect(flags.platform == "linux/arm64")
        #expect(flags.networks == ["app-net"])
        #expect(flags.entrypoint == "/bin/sh")
        #expect(flags.readOnly == true)
        #expect(flags.useInit == true)
        #expect(flags.rosetta == true)
        #expect(flags.ssh == true)
        #expect(flags.shmSize == "64m")
        #expect(flags.tmpFs == ["/tmp/scratch"])
        #expect(registry.scheme == "http")
    }

    @Test func managementFlagsMapMultipleNetworksAndMounts() {
        let options = RunOptions(
            reference: "local/web:1.0",
            networks: ["app-net", "data-net,mtu=1400"],
            mounts: ["type=bind,source=/host/data,target=/data,readonly"]
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        #expect(flags.networks == ["app-net", "data-net,mtu=1400"])
        #expect(flags.mounts == ["type=bind,source=/host/data,target=/data,readonly"])
    }

    @Test func processFlagsMapEnvFileAndUlimits() {
        let options = RunOptions(
            reference: "local/web:1.0",
            envFile: ["/host/.env"],
            ulimits: ["nofile=1024:2048"]
        )
        let flags = LiveContainerService.runProcessFlags(for: options)
        #expect(flags.envFile == ["/host/.env"])
        #expect(flags.ulimits == ["nofile=1024:2048"])
    }

    @Test func managementFlagsMapInteractiveVirtualizationCapsAndCidFile() {
        let options = RunOptions(
            reference: "local/web:1.0",
            virtualization: true,
            capAdd: ["CAP_NET_RAW", "ALL"],
            capDrop: ["CAP_SYS_ADMIN"],
            cidFile: "/tmp/cid.txt"
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        #expect(flags.virtualization == true)
        #expect(flags.capAdd == ["CAP_NET_RAW", "ALL"])
        #expect(flags.capDrop == ["CAP_SYS_ADMIN"])
        #expect(flags.cidfile == "/tmp/cid.txt")
    }

    @Test func dnsFamilyMapsWhenNoDnsIsFalse() {
        let options = RunOptions(
            reference: "local/web:1.0",
            dns: ["1.1.1.1", "8.8.8.8"],
            dnsDomain: "example.com",
            dnsOptions: ["ndots:5"],
            dnsSearch: ["corp.example.com"]
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        #expect(flags.dnsDisabled == false)
        #expect(flags.dns.nameservers == ["1.1.1.1", "8.8.8.8"])
        #expect(flags.dns.domain == "example.com")
        #expect(flags.dns.options == ["ndots:5"])
        #expect(flags.dns.searchDomains == ["corp.example.com"])
    }

    @Test func noDnsSuppressesTheRestOfTheDnsFamily() {
        let options = RunOptions(
            reference: "local/web:1.0",
            dns: ["1.1.1.1"],
            dnsDomain: "example.com",
            dnsOptions: ["ndots:5"],
            dnsSearch: ["corp.example.com"],
            noDns: true
        )
        let flags = LiveContainerService.runManagementFlags(for: options)
        #expect(flags.dnsDisabled == true)
        #expect(flags.dns.nameservers.isEmpty)
        #expect(flags.dns.domain == nil)
        #expect(flags.dns.options.isEmpty)
        #expect(flags.dns.searchDomains.isEmpty)
    }

    @Test func resourceFlagsMapCpusAndMemoryOmittingEmptyMemory() {
        let withValues = LiveContainerService.runResourceFlags(
            for: RunOptions(reference: "local/web:1.0", cpus: 2, memory: "1g")
        )
        #expect(withValues.cpus == 2)
        #expect(withValues.memory == "1g")

        let withEmptyMemory = LiveContainerService.runResourceFlags(
            for: RunOptions(reference: "local/web:1.0", memory: "")
        )
        #expect(withEmptyMemory.memory == nil)
    }

    @Test func emptyOptionalStringsAreOmittedNotPassedAsFlags() {
        let options = RunOptions(
            reference: "local/web:1.0",
            name: "",
            platform: "",
            workdir: "",
            user: "",
            entrypoint: "",
            memory: "",
            shmSize: "",
            cidFile: "",
            dnsDomain: ""
        )
        let management = LiveContainerService.runManagementFlags(for: options)
        let process = LiveContainerService.runProcessFlags(for: options)
        let resource = LiveContainerService.runResourceFlags(for: options)
        #expect(management.name == nil)
        #expect(management.platform == nil)
        #expect(management.networks.isEmpty)
        #expect(process.cwd == nil)
        #expect(process.user == nil)
        #expect(management.entrypoint == nil)
        #expect(resource.memory == nil)
        #expect(management.shmSize == nil)
        #expect(management.cidfile == "")
        #expect(management.dns.domain == nil)
    }
}

// MARK: - LiveContainerService machine* mapping (pure MachineCreateOptions -> native API inputs)
//
// `createMachine` now calls `MachineClient.machineConfigFromFlags` natively (XPC API) instead of
// shelling out to `container machine create`. Unlike the CLI, the native API doesn't derive a
// default machine ID from the image reference for us, so that derivation is now our own pure
// function too, alongside the `Flags.*` mapping (see `RunFlagsMappingTests` above).

struct MachineCreateMappingTests {

    @Test func machineIDUsesNameWhenGiven() throws {
        let id = try LiveContainerService.machineID(
            for: MachineCreateOptions(reference: "alpine:3.22", name: "dev-box")
        )
        #expect(id == "dev-box")
    }

    @Test func machineIDFallsBackToDerivationWhenNameIsEmpty() throws {
        let id = try LiveContainerService.machineID(
            for: MachineCreateOptions(reference: "alpine:3.22", name: "")
        )
        #expect(id == "alpine-3.22")
    }

    @Test func machineIDDerivesFromImageTagWhenNameOmitted() throws {
        let id = try LiveContainerService.machineID(for: MachineCreateOptions(reference: "alpine:3.22"))
        #expect(id == "alpine-3.22")
    }

    @Test func machineIDDerivationUsesLastPathComponentOfNamespacedImage() throws {
        let id = try LiveContainerService.machineID(
            for: MachineCreateOptions(reference: "docker.io/library/ubuntu:26.04")
        )
        #expect(id == "ubuntu-26.04")
    }

    @Test func machineManagementFlagsMapPlatformOmittingEmptyString() {
        let withPlatform = LiveContainerService.machineManagementFlags(
            for: MachineCreateOptions(reference: "alpine:3.22", platform: "linux/arm64")
        )
        #expect(withPlatform.platform == "linux/arm64")

        let withoutPlatform = LiveContainerService.machineManagementFlags(
            for: MachineCreateOptions(reference: "alpine:3.22", platform: "")
        )
        #expect(withoutPlatform.platform == nil)
    }

    @Test func machineRegistryFlagsMapInsecureRegistry() {
        let insecure = LiveContainerService.machineRegistryFlags(
            for: MachineCreateOptions(reference: "alpine:3.22", insecureRegistry: true)
        )
        #expect(insecure.scheme == "http")

        let secure = LiveContainerService.machineRegistryFlags(
            for: MachineCreateOptions(reference: "alpine:3.22")
        )
        #expect(secure.scheme == "auto")
    }

    @Test func machineBootConfigOverridesMapCpusMemoryAndHomeMount() {
        let overrides = LiveContainerService.machineBootConfigOverrides(
            for: MachineCreateOptions(reference: "alpine:3.22", cpus: 4, memory: "8G", homeMount: "ro")
        )
        #expect(overrides == ["cpus": "4", "memory": "8G", "home-mount": "ro"])
    }

    @Test func machineBootConfigOverridesOmitsUnsetAndEmptyStringFields() {
        let overrides = LiveContainerService.machineBootConfigOverrides(
            for: MachineCreateOptions(reference: "alpine:3.22", memory: "", homeMount: "")
        )
        #expect(overrides.isEmpty)
    }
}

// MARK: - LiveContainerService.mapNetwork (NetworkResource -> Network)

struct NetworkMappingTests {

    private func makeResource(name: String, subnet: String, gateway: String) throws -> NetworkResource {
        let configuration = try NetworkConfiguration(
            name: name,
            mode: .nat,
            plugin: "container-network-vmnet"
        )
        let status = NetworkStatus(
            ipv4Subnet: try CIDRv4(subnet),
            ipv4Gateway: try IPv4Address(gateway),
            ipv6Subnet: nil
        )
        return NetworkResource(configuration: configuration, status: status)
    }

    @Test func mapNetworkReadsSubnetAndGatewayFromRuntimeStatus() throws {
        let resource = try makeResource(name: "default", subnet: "192.168.64.0/24", gateway: "192.168.64.1")
        let network = LiveContainerService.mapNetwork(resource)
        #expect(network.subnet == "192.168.64.0/24")
        #expect(network.gateway == "192.168.64.1")
    }

    @Test func mapNetworkFlagsTheDefaultNetworkByName() throws {
        let resource = try makeResource(name: "default", subnet: "192.168.64.0/24", gateway: "192.168.64.1")
        let network = LiveContainerService.mapNetwork(resource)
        #expect(network.isDefault == true)
    }

    @Test func mapNetworkDoesNotFlagCustomNetworksAsDefault() throws {
        let resource = try makeResource(name: "app-net", subnet: "192.168.65.0/24", gateway: "192.168.65.1")
        let network = LiveContainerService.mapNetwork(resource)
        #expect(network.isDefault == false)
    }
}

// MARK: - MockContainerService

@MainActor
struct MockContainerServiceTests {

    @Test func seedsExpectedContainersAndImages() {
        let mock = MockContainerService()
        #expect(mock.daemonState.isConnectedCase)
        #expect(!mock.containers.isEmpty)
        #expect(!mock.images.isEmpty)
        #expect(mock.buildContexts["local/web:1.4"]?.contextPath == "/Users/dev/projects/web")
    }

    /// Catches retain cycles (e.g. a Task or closure capturing `self` strongly instead of
    /// weakly): if nothing outside this scope holds a reference, ARC deallocates `service` the
    /// moment the `do` block ends, so `weakRef` reads nil. Scoped to the mock rather than
    /// `LiveContainerService` because the live service dials a real daemon and writes to
    /// Application Support on init — not appropriate for a unit test's side effects.
    @Test func doesNotLeakAfterGoingOutOfScope() {
        weak var weakRef: MockContainerService?
        do {
            let service = MockContainerService()
            weakRef = service
        }
        #expect(weakRef == nil)
    }

    @Test func startDaemonTransitionsStoppedToConnected() async {
        let mock = MockContainerService()
        mock.daemonState = .installedButStopped
        await mock.startDaemon()
        #expect(mock.daemonState.isConnectedCase)
    }

    @Test func startContainerFlipsStatusToRunning() async throws {
        let mock = MockContainerService()
        guard let stopped = mock.containers.first(where: { $0.status == .stopped }) else {
            Issue.record("Fixture expected at least one stopped container")
            return
        }
        try await mock.startContainer(stopped.id)
        #expect(mock.containers.first(where: { $0.id == stopped.id })?.status == .running)
    }

    @Test func deleteContainerRemovesIt() async throws {
        let mock = MockContainerService()
        let id = mock.containers[0].id
        try await mock.deleteContainer(id)
        #expect(!mock.containers.contains { $0.id == id })
    }

    @Test func buildImageStreamsLogsAndAppendsBuiltImage() async throws {
        let mock = MockContainerService()
        let countBefore = mock.images.count
        var lines: [String] = []
        let options = BuildOptions(reference: "local/newapp:1.0", contextPath: "/tmp/newapp")
        try await mock.buildImage(options: options) { lines.append($0) }

        #expect(!lines.isEmpty)
        #expect(mock.images.count == countBefore + 1)
        let built = mock.images.first { $0.fullName == "local/newapp:1.0" }
        #expect(built?.source == .built)
    }

    @Test func buildImageCancellationThrowsAndDoesNotAppendImage() async throws {
        let mock = MockContainerService()
        let countBefore = mock.images.count
        let options = BuildOptions(reference: "local/cancelled:1.0", contextPath: "/tmp/x")

        let task = Task {
            try await mock.buildImage(options: options) { _ in }
        }
        task.cancel()

        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(mock.images.count == countBefore)
    }

    @Test func runContainerWithStartAppendsRunningContainer() async throws {
        let mock = MockContainerService()
        let countBefore = mock.containers.count
        let options = RunOptions(reference: "local/newapp:1.0", name: "newapp-1", start: true)
        try await mock.runContainer(options: options)

        #expect(mock.containers.count == countBefore + 1)
        let created = mock.containers.first { $0.id == "newapp-1" }
        #expect(created?.status == .running)
        #expect(created?.image == "local/newapp:1.0")
    }

    @Test func runContainerWithStartFalseAppendsStoppedContainer() async throws {
        let mock = MockContainerService()
        let options = RunOptions(reference: "local/newapp:1.0", name: "newapp-2", start: false)
        try await mock.runContainer(options: options)

        let created = mock.containers.first { $0.id == "newapp-2" }
        #expect(created?.status == .stopped)
    }

    @Test func runContainerParsesPortMappings() async throws {
        let mock = MockContainerService()
        let options = RunOptions(reference: "local/newapp:1.0", name: "newapp-3", ports: ["8080:80"])
        try await mock.runContainer(options: options)

        let created = mock.containers.first { $0.id == "newapp-3" }
        #expect(created?.ports == [PortMapping(host: 8080, container: 80)])
    }

    @Test func runContainerAttachedReturnsOutputAndLeavesContainerStopped() async throws {
        let mock = MockContainerService()
        let options = RunOptions(reference: "local/newapp:1.0", name: "newapp-4", command: ["pwd"], attach: true)
        let output = try await mock.runContainer(options: options)

        #expect(!output.isEmpty)
        let created = mock.containers.first { $0.id == "newapp-4" }
        #expect(created?.status == .stopped)
    }

    @Test func runContainerDetachedReturnsNoOutputAndLeavesContainerRunning() async throws {
        let mock = MockContainerService()
        let options = RunOptions(reference: "local/newapp:1.0", name: "newapp-5", attach: false)
        let output = try await mock.runContainer(options: options)

        #expect(output.isEmpty)
        let created = mock.containers.first { $0.id == "newapp-5" }
        #expect(created?.status == .running)
    }

    @Test func createMachineWithBootAppendsRunningMachine() async throws {
        let mock = MockContainerService()
        let countBefore = mock.machines.count
        let options = MachineCreateOptions(reference: "alpine:3.22", name: "test-machine-1", boot: true)
        try await mock.createMachine(options: options)

        #expect(mock.machines.count == countBefore + 1)
        let created = mock.machines.first { $0.id == "test-machine-1" }
        #expect(created?.status == .running)
        #expect(created?.image == "alpine:3.22")
    }

    @Test func createMachineWithBootFalseAppendsStoppedMachine() async throws {
        let mock = MockContainerService()
        let options = MachineCreateOptions(reference: "alpine:3.22", name: "test-machine-2", boot: false)
        try await mock.createMachine(options: options)

        let created = mock.machines.first { $0.id == "test-machine-2" }
        #expect(created?.status == .stopped)
    }

    @Test func pullImageAppendsPulledImage() async throws {
        let mock = MockContainerService()
        let countBefore = mock.images.count
        try await mock.pullImage(reference: "docker.io/library/redis:7")
        #expect(mock.images.count == countBefore + 1)
        #expect(mock.images.last?.source == .pulled)
    }
}

private extension DaemonState {
    var isConnectedCase: Bool {
        if case .connected = self { return true }
        return false
    }
}
