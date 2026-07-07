//
//  BerthlyTests.swift
//  BerthlyTests
//
//  Created by Henry Wang on 6/28/26.
//

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import MachineAPIClient
import SwiftTerm
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

// MARK: - PinnedItems Codable

struct PinnedItemsCodableTests {

    @Test func roundTripPreservesBothSets() throws {
        let original = PinnedItems(containers: ["c1", "c2"], machines: ["m1"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PinnedItems.self, from: data)
        #expect(decoded.containers == original.containers)
        #expect(decoded.machines == original.machines)
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

// MARK: - Exec session config (Terminal, M3)

struct ExecProcessConfigurationTests {

    @Test func overridesExecutableArgumentsAndTerminalOnly() {
        let initProcess = ProcessConfiguration(
            executable: "/app/server",
            arguments: ["--port", "8080"],
            environment: ["NODE_ENV=production"],
            workingDirectory: "/app",
            terminal: false,
            user: .raw(userString: "1000:1000")
        )
        let config = LiveContainerService.execProcessConfiguration(basedOn: initProcess, shell: "/bin/bash")
        #expect(config.executable == "/bin/bash")
        #expect(config.arguments == [])
        #expect(config.terminal == true)
        // Everything else carries over from the container's own init process so an exec'd
        // shell sees the same env/user/cwd a real `container exec` would.
        #expect(config.environment == ["NODE_ENV=production"])
        #expect(config.workingDirectory == "/app")
        #expect(config.user == .raw(userString: "1000:1000"))
    }

    @Test func shellCandidatesTryBashBeforeSh() {
        #expect(LiveContainerService.execShellCandidates == ["/bin/bash", "/bin/sh"])
    }

    @Test func machineShellUsesMachineInitWithLoginShellFlag() {
        let config = LiveContainerService.machineShellProcessConfiguration(
            home: "/home/dev",
            user: .id(uid: 501, gid: 20)
        )
        #expect(config.executable == "/sbin.machine/init")
        #expect(config.arguments == ["-s"])
        #expect(config.terminal == true)
        #expect(config.workingDirectory == "/home/dev")
        #expect(config.user == .id(uid: 501, gid: 20))
    }
}

// MARK: - Terminal themes

struct TerminalThemeTests {

    @Test(arguments: TerminalTheme.allCases)
    func everyThemeHasExactlySixteenAnsiColors(theme: TerminalTheme) {
        // `TerminalView.installColors` silently no-ops if this isn't 16 — a regression here
        // wouldn't fail loudly at runtime, just quietly leave the old palette in place.
        #expect(theme.colors.ansi.count == 16)
    }

    @Test(arguments: TerminalTheme.allCases)
    func everyThemeHasANonEmptyDisplayName(theme: TerminalTheme) {
        #expect(!theme.displayName.isEmpty)
    }

    @Test func rawValueRoundTripsForAllCases() {
        for theme in TerminalTheme.allCases {
            #expect(TerminalTheme(rawValue: theme.rawValue) == theme)
        }
    }

    @Test func hexConversionMapsBlackAndWhiteToChannelExtremes() {
        let black = SwiftTerm.Color(hex: "000000")
        #expect(black.red == 0)
        #expect(black.green == 0)
        #expect(black.blue == 0)

        let white = SwiftTerm.Color(hex: "FFFFFF")
        #expect(white.red == 65535)
        #expect(white.green == 65535)
        #expect(white.blue == 65535)
    }
}

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

// MARK: - LiveContainerService.mapHomeMount (MachineConfig.HomeMountOption -> MachineHomeMount)

struct MachineHomeMountMappingTests {

    @Test func mapsReadOnly() {
        #expect(LiveContainerService.mapHomeMount(.ro) == .readOnly)
    }

    @Test func mapsReadWrite() {
        #expect(LiveContainerService.mapHomeMount(.rw) == .readWrite)
    }

    @Test func mapsNone() {
        #expect(LiveContainerService.mapHomeMount(.none) == .none)
    }
}

// MARK: - ContainerCompatibility

struct ContainerCompatibilityTests {

    @Test func exactMatchIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0", required: "1.1.0"))
    }

    @Test func patchDifferenceIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.7", required: "1.1.0"))
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0", required: "1.1.3"))
    }

    // Post-1.0 semver: a daemon with a newer minor is additive and safe for this client.
    @Test func newerMinorIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.2.0", required: "1.1.0"))
    }

    @Test func olderMinorIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "1.0.4", required: "1.1.0"))
    }

    @Test func majorDifferenceIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "2.0.0", required: "1.1.0"))
        #expect(!ContainerCompatibility.isCompatible(installed: "0.9.0", required: "1.1.0"))
    }

    @Test func untaggedBuildSuffixIsIgnored() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0-3-gabcdef", required: "1.1.0"))
    }

    @Test func malformedVersionIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "not-a-version", required: "1.1.0"))
    }

    // Mismatch direction decides which gate the user sees: tooOld offers the in-place update,
    // tooNew must never touch the install (upstream can't downgrade in place).
    @Test func mismatchIsNilWhenCompatible() {
        #expect(ContainerCompatibility.mismatch(installed: "1.1.0", required: "1.1.0") == nil)
        #expect(ContainerCompatibility.mismatch(installed: "1.2.0", required: "1.1.0") == nil)
    }

    @Test func mismatchOlderMinorIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "1.0.4", required: "1.1.0") == .tooOld)
    }

    @Test func mismatchOlderMajorIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "0.9.0", required: "1.1.0") == .tooOld)
    }

    @Test func mismatchNewerMajorIsTooNew() {
        #expect(ContainerCompatibility.mismatch(installed: "2.0.0", required: "1.1.0") == .tooNew)
    }

    // A newer minor within the same major is compatible, so the only way "newer" mismatches is
    // by major — there is no tooNew inside major 1.
    @Test func mismatchMalformedIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "garbage", required: "1.1.0") == .tooOld)
    }

    // Regression: `apiServerVersion` from the health-check ping is `ReleaseVersion.singleLine`'s
    // full descriptive output, not a bare semver — "container-apiserver" contains its own hyphen,
    // which previously broke a naive split(separator: "-") into treating "container" as the version.
    @Test func realApiServerVersionStringIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(
            installed: "container-apiserver version 1.0.0 (build: release, commit: abc1234)",
            required: "1.0.0"
        ))
    }

    @Test func extractVersionPullsNumberOutOfDescriptiveString() {
        #expect(ContainerCompatibility.extractVersion(
            from: "container-apiserver version 1.0.0 (build: release, commit: abc1234)"
        ) == "1.0.0")
    }

    @Test func extractVersionReturnsNilWhenNoVersionPresent() {
        #expect(ContainerCompatibility.extractVersion(from: "not-a-version") == nil)
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

    @Test func stopDaemonTransitionsConnectedToStopped() async {
        let mock = MockContainerService()
        mock.daemonState = .connected
        await mock.stopDaemon()
        guard case .installedButStopped = mock.daemonState else {
            Issue.record("Expected .installedButStopped, got \(mock.daemonState)")
            return
        }
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

    @Test func togglePinContainerAddsThenRemoves() {
        let mock = MockContainerService()
        let id = mock.containers[0].id
        mock.togglePinContainer(id)
        #expect(mock.isContainerPinned(id))
        mock.togglePinContainer(id)
        #expect(!mock.isContainerPinned(id))
    }

    @Test func togglePinMachineAddsThenRemoves() {
        let mock = MockContainerService()
        let id = mock.machines[0].id
        mock.togglePinMachine(id)
        #expect(mock.isMachinePinned(id))
        mock.togglePinMachine(id)
        #expect(!mock.isMachinePinned(id))
    }

    @Test func deletingPinnedContainerRemovesThePin() async throws {
        let mock = MockContainerService()
        let id = mock.containers[0].id
        mock.togglePinContainer(id)
        try await mock.deleteContainer(id)
        #expect(!mock.isContainerPinned(id))
    }

    @Test func deletingPinnedMachineRemovesThePin() async throws {
        let mock = MockContainerService()
        let id = mock.machines[0].id
        mock.togglePinMachine(id)
        try await mock.deleteMachine(id)
        #expect(!mock.isMachinePinned(id))
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

    private static func seedDiskUsage() -> DiskUsageSummary {
        DiskUsageSummary(
            images: .init(total: 12, active: 4, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
            containers: .init(total: 6, active: 2, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
            volumes: .init(total: 3, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 0)
        )
    }

    @Test func pruneImagesFreesReclaimableBytesAndLeavesOtherCategoriesUntouched() async throws {
        let mock = MockContainerService()
        mock.diskUsage = Self.seedDiskUsage()

        let result = try await mock.pruneImages()
        #expect(result.imagesFreedBytes == 1_100_000_000)
        #expect(result.deletedImageCount == 8)
        #expect(result.containersFreedBytes == 0)

        let usage = try #require(mock.diskUsage)
        #expect(usage.images.reclaimableBytes == 0)
        #expect(usage.images.sizeBytes == 3_400_000_000 - 1_100_000_000)
        #expect(usage.images.total == usage.images.active)
        #expect(usage.containers.reclaimableBytes == 90_000_000)  // untouched
        #expect(usage.volumes.reclaimableBytes == 0)              // untouched
    }

    @Test func pruneStoppedContainersFreesReclaimableBytesAndLeavesOtherCategoriesUntouched() async throws {
        let mock = MockContainerService()
        mock.diskUsage = Self.seedDiskUsage()

        let result = try await mock.pruneStoppedContainers()
        #expect(result.containersFreedBytes == 90_000_000)
        #expect(result.deletedContainerCount == 4)
        #expect(result.imagesFreedBytes == 0)

        let usage = try #require(mock.diskUsage)
        #expect(usage.containers.reclaimableBytes == 0)
        #expect(usage.containers.sizeBytes == 240_000_000 - 90_000_000)
        #expect(usage.containers.total == usage.containers.active)
        #expect(usage.images.reclaimableBytes == 1_100_000_000)  // untouched
        #expect(usage.volumes.reclaimableBytes == 0)             // untouched
    }

    @Test func pruneMethodsAreNoOpsWhenDiskUsageIsNil() async throws {
        let mock = MockContainerService()
        mock.diskUsage = nil

        let imagesResult = try await mock.pruneImages()
        let containersResult = try await mock.pruneStoppedContainers()

        #expect(imagesResult.imagesFreedBytes == 0)
        #expect(containersResult.containersFreedBytes == 0)
        #expect(mock.diskUsage == nil)
    }

    // MARK: - pruneAll (ContainerServiceBase default)

    @Test func pruneAllCombinesBothPhasesWhenBothSucceed() async throws {
        let mock = MockContainerService()
        mock.diskUsage = Self.seedDiskUsage()

        let outcome = await mock.pruneAll()
        #expect(outcome.failureMessages.isEmpty)
        #expect(outcome.errorAlertMessage == nil)
        #expect(outcome.result.imagesFreedBytes == 1_100_000_000)
        #expect(outcome.result.containersFreedBytes == 90_000_000)
        #expect(outcome.result.deletedImageCount == 8)
        #expect(outcome.result.deletedContainerCount == 4)
    }
}

@MainActor
struct ContainerServiceBaseSummaryTests {

    private func makeContainer(id: String, status: Berthly.ContainerStatus) -> Container {
        Container(id: id, name: id, image: "i", status: status, ports: [], cpuPercent: 0,
                  memoryMB: 0, memoryLimitMB: 0, networkIOString: "", uptime: "", command: "",
                  mounts: [], networks: [], environment: [])
    }

    private func makeMachine(id: String, status: Berthly.ContainerStatus, isUtility: Bool = false) -> Machine {
        Machine(id: id, name: id, image: "i", status: status, isUtility: isUtility, diskUsedGB: 0,
                diskTotalGB: 0, uptimeString: "", kernel: "", resources: "", created: "",
                homeMount: .none)
    }

    @Test func runningContainersAndErrorCountFilterByStatus() {
        let mock = MockContainerService()
        mock.containers = [
            makeContainer(id: "1", status: .running),
            makeContainer(id: "2", status: .stopped),
            makeContainer(id: "3", status: .error),
        ]
        #expect(mock.runningContainers.map(\.id) == ["1"])
        #expect(mock.errorContainerCount == 1)
    }

    @Test func runningMachinesAndErrorCountFilterByStatus() {
        let mock = MockContainerService()
        mock.machines = [
            makeMachine(id: "m1", status: .running),
            makeMachine(id: "m2", status: .stopped),
            makeMachine(id: "m3", status: .error),
        ]
        #expect(mock.runningMachines.map(\.id) == ["m1"])
        #expect(mock.errorMachineCount == 1)
    }

    @Test func runningMachinesAndErrorCountExcludeUtilityMachines() {
        let mock = MockContainerService()
        mock.machines = [
            makeMachine(id: "m1", status: .running),
            makeMachine(id: "util-running", status: .running, isUtility: true),
            makeMachine(id: "util-error", status: .error, isUtility: true),
        ]
        #expect(mock.runningMachines.map(\.id) == ["m1"])
        #expect(mock.errorMachineCount == 0)
    }

    @Test func pinnedContainersFiltersByPinnedIDsRegardlessOfStatus() {
        let mock = MockContainerService()
        mock.containers = [
            makeContainer(id: "1", status: .running),
            makeContainer(id: "2", status: .stopped),
            makeContainer(id: "3", status: .running),
        ]
        mock.pinnedContainerIDs = ["2", "3"]
        #expect(Set(mock.pinnedContainers.map(\.id)) == ["2", "3"])
    }

    @Test func pinnedMachinesFiltersByPinnedIDsAndExcludesUtility() {
        let mock = MockContainerService()
        mock.machines = [
            makeMachine(id: "m1", status: .stopped),
            makeMachine(id: "util", status: .running, isUtility: true),
        ]
        mock.pinnedMachineIDs = ["m1", "util"]
        #expect(mock.pinnedMachines.map(\.id) == ["m1"])
    }
}

private extension DaemonState {
    var isConnectedCase: Bool {
        if case .connected = self { return true }
        return false
    }
}
