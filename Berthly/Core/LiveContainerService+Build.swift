// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AsyncHTTPClient
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import Logging
import MachineAPIClient
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress
internal import ContainerPersistence
internal import ContainerPlugin

extension LiveContainerService {
    /// Resolves the Dockerfile to build from: an explicit path if given, else the CLI's own
    /// fallback (`Dockerfile`, then `Containerfile`, in `contextPath`) via `BuildFile.resolvePath`.
    nonisolated static func resolveDockerfilePath(for options: BuildOptions) throws -> String {
        if let file = options.dockerfilePath, !file.isEmpty {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist: \(file)")
            }
            return file
        }
        guard let resolved = try BuildFile.resolvePath(contextDir: options.contextPath),
              FileManager.default.fileExists(atPath: resolved) else {
            throw ContainerizationError(.invalidArgument, message: "No Dockerfile or Containerfile found in \(options.contextPath)")
        }
        return resolved
    }

    /// Replicates the CLI's `--secret id=<key>[,env=<VAR>|,src=<path>]` parsing
    /// (`BuildCommand.validate()`), resolving straight to `Data` since this app has no
    /// separate validate/run phase to defer the env/file read into.
    nonisolated static func resolveBuildSecrets(_ raw: [String]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for secret in raw {
            let parts = secret.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].hasPrefix("id=") else {
                throw ContainerizationError(.invalidArgument, message: "secret must start with id=<key>: \(secret)")
            }
            let key = String(parts[0].dropFirst(3))
            guard !key.isEmpty, !key.contains("=") else {
                throw ContainerizationError(.invalidArgument, message: "invalid secret id: \(secret)")
            }
            if parts.count == 1 || parts[1].hasPrefix("env=") {
                let envName = parts.count == 1 ? key : String(parts[1].dropFirst(4))
                guard let ptr = getenv(envName) else {
                    throw ContainerizationError(.invalidArgument, message: "secret env var doesn't exist: \(envName)")
                }
                result[key] = Data(bytes: ptr, count: strlen(ptr))
            } else if parts[1].hasPrefix("src=") {
                let path = String(parts[1].dropFirst(4))
                result[key] = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                throw ContainerizationError(.invalidArgument, message: "invalid secret value: \(secret)")
            }
        }
        return result
    }

    /// Normalizes the target image reference the same way the CLI does (`Reference.parse` +
    /// `.normalize()`), falling back to a random tag when none was given (matches
    /// `BuildCommand.targetImageNames`'s default).
    nonisolated static func buildTags(for options: BuildOptions) throws -> [String] {
        let name = options.reference.isEmpty ? UUID().uuidString.lowercased() : options.reference
        let reference = try Reference.parse(name)
        reference.normalize()
        return [reference.description]
    }

    /// Parses `options.platform` (comma-separated `os/arch[/variant]` entries) or falls back to
    /// the host's own linux platform — the CLI's default when no `--platform`/`--os`/`--arch` is given.
    nonisolated static func buildPlatforms(for options: BuildOptions) throws -> [Platform] {
        guard let raw = options.platform, !raw.isEmpty else {
            return [try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")]
        }
        return try raw.split(separator: ",").map { try Platform(from: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Maps `BuildOptions.ssh` to `Builder.BuildConfig.ssh`: `"default"` forwards the host's agent
    /// socket, `""` requests nothing. Throws when ssh is requested without `SSH_AUTH_SOCK`, matching
    /// `BuildCommand`'s `--ssh` validation; otherwise buildkit would expect an agent the builder never
    /// gets, and fail confusingly inside a `RUN --mount=type=ssh` step.
    nonisolated static func buildConfigSSH(for options: BuildOptions, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard options.ssh else { return "" }
        guard environment["SSH_AUTH_SOCK"] != nil else {
            throw ContainerizationError(.invalidArgument, message: "SSH agent forwarding requested, but SSH_AUTH_SOCK is not set.")
        }
        return "default"
    }

    /// Whether the builder container gets SSH agent forwarding: requested *and* a socket exists, as
    /// upstream's `BuilderStart.start()` checks. A defensive mirror: `buildConfigSSH` already throws
    /// for a build requesting ssh without a socket, and `startBuilder(_:)` passes `ssh: false`.
    nonisolated static func resolveBuilderSSH(requested: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        requested && environment["SSH_AUTH_SOCK"] != nil
    }

    /// Resolves the builder to this build's cpus/memory/ssh, then dials it over VSOCK.
    /// `startBuilderContainer` always runs first, as in `BuildCommand.run`, so a running builder with
    /// stale settings is recreated instead of silently reused (a cheap no-op when nothing changed).
    /// So a malformed `--memory` fails here even when a builder is already running. The dial retries
    /// every 5s up to 300s: the shim's gRPC server may not be accepting connections yet.
    private func dialOrStartBuilder(
        containerSystemConfig: ContainerSystemConfig,
        cpus: Int64?,
        memory: String?,
        ssh: Bool,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws -> (builder: ContainerBuild.Builder, group: MultiThreadedEventLoopGroup) {
        let deadline = Date().addingTimeInterval(300)
        // `startBuilderContainer` only calls `onLog` when it actually does work (fresh create or
        // recreate) — this tracks that so "Build environment ready." only bookends a real start,
        // not the silent fast path where a matching builder was already running.
        var announcedWork = false
        try await startBuilderContainer(containerSystemConfig: containerSystemConfig, cpus: cpus, memory: memory, ssh: ssh, onLog: { line in
            announcedWork = true
            onLog(line)
        })
        while true {
            do {
                let socket = try await ContainerClient().dial(id: ContainerBuild.Builder.builderContainerId, port: 8088)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                do {
                    let builder = try await ContainerBuild.Builder(socket: socket, group: group, logger: Self.log)
                    _ = try await builder.info()
                    if announcedWork { onLog("Build environment ready.") }
                    return (builder, group)
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
            } catch {
                guard Date() < deadline else {
                    throw ContainerizationError(.timeout, message: "Timed out waiting for the builder to start.")
                }
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Replica of `ContainerBuild.Builder.start` (public since 1.6.0, apple/container#2298): reuses
    /// a running/stopped "buildkit" container when its image/cpu/memory/ssh/DNS still match, otherwise
    /// (re)creates it with the CLI's mounts, network, and kernel, then bootstraps the shim. Not
    /// called directly (#210): upstream reports "Fetching BuildKit image" even when it does no
    /// work, which breaks the `onLog` "did work" signal `dialOrStartBuilder` relies on, and it
    /// also recreates on `BUILDKIT_COLORS`/`NO_COLOR` drift, which a Finder-launched app never
    /// has, so alternating with a shell that sets them would discard the build cache each time.
    func startBuilderContainer(
        containerSystemConfig: ContainerSystemConfig,
        cpus: Int64?,
        memory: String?,
        ssh: Bool,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        let builderImage = containerSystemConfig.build.image
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportsMount = systemHealth.appRoot.appendingPathComponent("builder").path
        if !FileManager.default.fileExists(atPath: exportsMount) {
            try FileManager.default.createDirectory(atPath: exportsMount, withIntermediateDirectories: true)
        }

        let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
        let resources = try Parser.resources(
            cpus: cpus,
            memory: memory,
            defaultCPUs: containerSystemConfig.build.cpus,
            defaultMemory: containerSystemConfig.build.memory
        )
        let wantsSSH = Self.resolveBuilderSSH(requested: ssh)
        let dns = Self.builderDNS(defaults: containerSystemConfig.container.dns)

        let client = ContainerClient()
        let builderContainerId = ContainerBuild.Builder.builderContainerId
        if let existing = try? await client.get(id: builderContainerId) {
            let needsRecreate = Self.builderNeedsRecreate(
                existing.configuration, image: builderImage, resources: resources, ssh: wantsSSH, dns: dns
            )
            switch existing.status {
            case .running:
                guard needsRecreate else { return }
                onLog("Restarting the build environment for updated settings…")
                try await client.stop(id: existing.id)
                try await client.delete(id: existing.id)
            case .stopped:
                if needsRecreate {
                    onLog("Restarting the build environment for updated settings…")
                    try await client.delete(id: existing.id)
                } else {
                    do {
                        try await bootstrapBuilderShim(client: client, id: existing.id)
                        return
                    } catch {
                        // Upstream's fallback: a stopped builder that won't restart is rebuilt
                        // rather than failing the build. bootstrapBuilderShim already deleted it.
                        Self.log.warning("failed to restart stopped builder, recreating", metadata: ["error": "\(error)"])
                        onLog("Couldn't restart the build environment; recreating it…")
                    }
                }
            case .stopping:
                throw ContainerizationError(.invalidState, message: "Builder is stopping; wait until it's fully stopped before rebuilding.")
            case .unknown:
                break
            }
        } else {
            onLog("Starting the build environment…")
        }

        let useRosetta = containerSystemConfig.build.rosetta
        let shimArguments = ["--debug", "--vsock", useRosetta ? nil : "--enable-qemu"].compactMap { $0 }

        guard ManagedContainer.nameValid(builderContainerId) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(builderContainerId) is not a valid container ID")
        }

        // The slow part on first build. `fetch` streams size events only when it actually pulls —
        // a cached image resolves via `get` with no events — so the reporter emits its throttled
        // "Downloading builder image… N MB" progress lines exactly when a real download happens,
        // and stays silent otherwise (no misleading line on the cached path).
        let pullReporter = DownloadReporter(label: "Downloading builder image (\(builderImage))", onLog: onLog)
        let image = try await ClientImage.fetch(
            reference: builderImage,
            platform: builderPlatform,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: pullReporter.handler
        )
        _ = try await image.getCreateSnapshot(platform: builderPlatform)

        let imageDesc = ImageDescription(reference: builderImage, descriptor: image.descriptor)
        let environment = try await image.config(for: builderPlatform).config?.env ?? []

        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: shimArguments,
            environment: environment,
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDesc, process: processConfig)
        config.resources = resources
        config.ssh = wantsSSH
        config.labels = [
            ResourceLabelKeys.plugin: "builder",
            ResourceLabelKeys.role: ResourceRoleValues.builder
        ]
        config.capAdd = ["ALL"]
        config.mounts = [
            Filesystem(type: .tmpfs, source: "", destination: "/run", options: []),
            Filesystem(type: .virtiofs, source: exportsMount, destination: "/var/lib/container-builder-shim/exports", options: [])
        ]
        config.rosetta = useRosetta

        guard let defaultNetwork = try await NetworkClient().builtin else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        config.networks = [
            AttachmentConfiguration(network: defaultNetwork.id, options: AttachmentOptions(hostname: builderContainerId))
        ]
        config.dns = dns

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        do {
            try await client.create(configuration: config, options: .default, kernel: kernel)
        } catch let error as ContainerizationError where error.code == .exists {
            // A concurrent `container build` created the builder while the image and kernel
            // were fetched; bootstrap is idempotent, so use the one it made (as upstream does).
        }
        try await bootstrapBuilderShim(client: client, id: builderContainerId)
    }

    /// The builder's DNS: `[container.dns]` from `config.toml` (apple/container#1614), else empty
    /// nameservers, which the runtime replaces with the network gateway's resolver. Same resolution
    /// as upstream's `Builder.start`: no host-domain fallback, and the four-argument `Flags.DNS`
    /// init, since the empty one leaves its `@Option`s in ArgumentParser's unset `.definition`
    /// state. Berthly used to hard-code `DNSConfiguration()`, whose default is `1.1.1.1`.
    nonisolated static func builderDNS(defaults: ContainerDNSConfig?) -> ContainerConfiguration.DNSConfiguration {
        Utility.dnsConfiguration(
            from: Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: []),
            defaults: defaults
        )
    }

    /// `config.ssh` gates the host↔guest agent-socket forwarding itself and is set only at
    /// creation — bootstrapBuilderShim's SSH_AUTH_SOCK env var just tells the shim where to look —
    /// so flipping ssh needs a recreate like an image/cpu/memory/DNS change. Unlike upstream, managed
    /// env (`BUILDKIT_COLORS`/`NO_COLOR`) is ignored; see `startBuilderContainer`.
    nonisolated static func builderNeedsRecreate(
        _ existing: ContainerConfiguration,
        image: String,
        resources: ContainerConfiguration.Resources,
        ssh: Bool,
        dns: ContainerConfiguration.DNSConfiguration
    ) -> Bool {
        // `?? .init()` (nameservers `1.1.1.1`) copies upstream's `dnsConfigurationChanged`, so the
        // CLI and Berthly agree on when a builder is stale instead of recreating each other's.
        let existingDNS = existing.dns ?? .init()
        return existing.image.reference != image
            || existing.resources.cpus != resources.cpus
            || existing.resources.memoryInBytes != resources.memoryInBytes
            || existing.ssh != ssh
            || existingDNS.nameservers != dns.nameservers
            || existingDNS.domain != dns.domain
            || existingDNS.searchDomains != dns.searchDomains
            || existingDNS.options != dns.options
    }

    /// Starts the `container-builder-shim` process inside a freshly created (or reused, stopped)
    /// builder container. Mirrors the CLI's private `startBuildKit` helper, but swaps `ProcessIO`
    /// for plain `stdio: [nil, nil, nil]` — matching the detached-bootstrap pattern used
    /// elsewhere in this service, since we don't need the shim's own stdio, only for it to be running.
    private func bootstrapBuilderShim(client: ContainerClient, id: String) async throws {
        do {
            var dynamicEnv: [String: String] = [:]
            if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
            }
            let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil], dynamicEnv: dynamicEnv)
            try await process.start()
        } catch {
            try? await client.stop(id: id)
            try? await client.delete(id: id)
            throw error
        }
    }

    /// Native `container build`: dials (auto-starting if needed) the "buildkit" builder and drives the
    /// CLI's `Builder.build(_:)` gRPC pipeline. `Builder.build` has no output callback; it writes to
    /// `config.terminal?.handle ?? stderr`, and a `Terminal` switches buildkit to ANSI "tty" mode. So
    /// `terminal: nil` gets plain line output on *this process's* stderr, which is dup2'd to a pipe
    /// for the build and restored after. Polling is paused for that window, as the only other
    /// plausible stderr writer.
    func buildImageImpl(options: BuildOptions, onLog: @MainActor @escaping (String) -> Void) async throws {
        // Guards against two overlapping builds corrupting each other's stderr redirection below
        // (see the dup2 discussion further down) — e.g. a Cancel that doesn't wait for the
        // in-flight build's cleanup to finish before the UI allows starting a new one.
        guard !isBuilding else {
            throw ContainerizationError(.invalidState, message: "A build is already in progress.")
        }
        isBuilding = true
        defer { isBuilding = false }

        // Validate all local, daemon-independent input up front — before touching the builder —
        // so a typo'd Dockerfile path or malformed --secret fails immediately instead of after
        // possibly waiting through a full builder auto-start (image fetch, VM boot, shim bootstrap).
        let dockerfilePath = try Self.resolveDockerfilePath(for: options)
        let dockerfileData = try Data(contentsOf: URL(fileURLWithPath: dockerfilePath))
        let dockerignoreData = try? Data(contentsOf: URL(fileURLWithPath: dockerfilePath + ".dockerignore"))
        let secretsData = try Self.resolveBuildSecrets(options.secrets)
        let tags = try Self.buildTags(for: options)
        let platforms = try Self.buildPlatforms(for: options)
        let sshConfig = try Self.buildConfigSSH(for: options)

        let containerSystemConfig = await resolvedSystemConfig()
        let builderConnection = try await dialOrStartBuilder(containerSystemConfig: containerSystemConfig,
                                                             cpus: options.cpus.map { Int64($0) },
                                                             memory: options.memory, ssh: options.ssh, onLog: onLog)
        let builder = builderConnection.builder
        let builderGroup = builderConnection.group
        defer {
            Task.detached {
                try? await builderGroup.shutdownGracefully()
            }
        }

        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let tempURL = systemHealth.appRoot.appendingPathComponent("builder").appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportDestination = tempURL.appendingPathComponent("out.tar")
        let export = ContainerBuild.Builder.BuildExport(
            type: "oci",
            destination: exportDestination,
            additionalFields: [:],
            rawValue: "type=oci"
        )

        let config = ContainerBuild.Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: options.buildArgs.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            secrets: secretsData,
            ssh: sshConfig,
            contextDir: options.contextPath,
            dockerfile: dockerfileData,
            dockerignore: dockerignoreData,
            labels: options.labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            noCache: options.noCache,
            platforms: platforms,
            terminal: nil,
            tags: tags,
            target: options.target ?? "",
            quiet: false,
            exports: [export],
            cacheIn: [],
            cacheOut: [],
            pull: options.pull,
            containerSystemConfig: containerSystemConfig
        )

        pollTask?.cancel()
        defer { startPolling() }

        // Redirect this process's own stderr into a pipe for the duration of the build so we can
        // stream it into `onLog`, then always restore it — `builder.build` writes there directly
        // (see doc comment above), and leaving it redirected past this point risks blocking any
        // other stderr writer once the pipe's kernel buffer fills, since nothing drains it anymore.
        let originalStderr = dup(STDERR_FILENO)
        guard originalStderr >= 0 else {
            throw ContainerizationError(.internalError, message: "failed to duplicate stderr for build log capture")
        }
        let pipe = Pipe()
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // A single dedicated reader for the pipe's entire lifetime, rather than a `readabilityHandler`
        // that gets installed then torn down mid-flight: `FileHandle.availableData` blocks until data
        // arrives or EOF, so looping it in one background task means there's no second, separate read
        // racing a `readabilityHandler = nil` teardown (which isn't guaranteed synchronous) to drain
        // whatever's left once the build finishes.
        let readHandle = pipe.fileHandleForReading
        let drainTask = Task.detached(priority: .userInitiated) {
            while true {
                let data = readHandle.availableData
                if data.isEmpty { return }
                guard let str = String(data: data, encoding: .utf8) else { continue }
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    await MainActor.run { onLog(line) }
                }
            }
        }

        func restoreStderrAndDrain() async {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            try? pipe.fileHandleForWriting.close()
            // Closing the write end above delivers EOF to the read loop, which then returns.
            await drainTask.value
        }

        do {
            try await builder.build(config)
        } catch {
            await restoreStderrAndDrain()
            throw error
        }
        await restoreStderrAndDrain()

        try Task.checkCancellation()

        let result = try await ClientImage.load(from: exportDestination.path, force: false)
        guard result.rejectedMembers.isEmpty else {
            throw ContainerizationError(.internalError, message: "Build archive contains invalid members: \(result.rejectedMembers)")
        }
        for image in result.images {
            try await image.unpack(platform: nil)
            for tag in tags {
                _ = try await image.tag(new: tag)
            }
        }

        await refresh()
    }
}
