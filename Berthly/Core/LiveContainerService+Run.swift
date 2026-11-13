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
    /// Pure translation of `RunOptions` into the vendored `container` package's own
    /// `Flags.Process`/`Flags.Management`/`Flags.Resource`/`Flags.Registry` argument bags —
    /// the same types the CLI's `run`/`create` commands build from parsed command-line flags,
    /// constructed here directly so `Utility.containerConfigFromFlags` can be called in-process
    /// over the native XPC API instead of shelling out to the `container` binary.
    /// Treats an empty string the same as `nil` — the UI already nils out blank fields before
    /// constructing `RunOptions`, but mapping this defensively keeps a blank field from turning
    /// into e.g. `cwd: ""` (a real, if empty, override) instead of "unset, use the image default".
    nonisolated static func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Shell fallback order tried when exec'ing into a running container — bash first (most
    /// full-featured), falling back to `sh` for minimal images (e.g. Alpine) that lack it.
    nonisolated static let execShellCandidates = ["/bin/bash", "/bin/sh"]

    /// Builds the `ProcessConfiguration` for an exec'd shell session from the container's own
    /// init process — same base the CLI's `container exec` uses (`ContainerExec.run()`) — so
    /// env/user/cwd match what a real exec would see, rather than starting from a blank slate.
    nonisolated static func execProcessConfiguration(basedOn initProcess: ProcessConfiguration, shell: String) -> ProcessConfiguration {
        var config = initProcess
        config.executable = shell
        config.arguments = []
        config.terminal = true
        return config
    }

    /// Builds the `ProcessConfiguration` for a machine's login shell — same approach the CLI's
    /// `container machine run` uses (`MachineRun.run()`): exec `/sbin.machine/init -s` (the
    /// machine bundle's init binary, which resolves the right shell for the user itself) inside
    /// the container backing the machine, rather than execing a shell directly. Takes `home`/
    /// `user` directly rather than a whole `MachineSnapshot` — those are the only two fields
    /// used, and it keeps this testable without constructing vendored OCI/platform fixtures.
    nonisolated static func machineShellProcessConfiguration(home: String, user: ProcessConfiguration.User) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
            arguments: ["-s"],
            environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            workingDirectory: home,
            terminal: true,
            user: user
        )
    }

    /// Runs on every boot, as the 1.6.1 CLI's `bootMachine` does: the script is idempotent and
    /// never writes the `initialized` marker. Never the guest init's old `-u` mode — 1.6.0 removed
    /// it (apple/container#2322), and the unknown flag falls through to `exec /sbin/init`, a second
    /// system init that tears the VM down (#213).
    nonisolated static func machineUserSetupProcessConfiguration(environment: [String]) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", MachineUserSetup.script],
            environment: environment,
            terminal: false
        )
    }

    nonisolated static func runProcessFlags(for options: RunOptions) -> Flags.Process {
        Flags.Process(
            cwd: nilIfEmpty(options.workdir),
            env: options.env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            envFile: options.envFile,
            gid: nil,
            interactive: options.interactive,
            tty: options.tty,
            uid: nil,
            ulimits: options.ulimits,
            user: nilIfEmpty(options.user)
        )
    }

    nonisolated static func runManagementFlags(for options: RunOptions) -> Flags.Management {
        let dns: Flags.DNS = options.noDns
            ? Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: [])
            : Flags.DNS(
                domain: nilIfEmpty(options.dnsDomain),
                nameservers: options.dns,
                options: options.dnsOptions,
                searchDomains: options.dnsSearch
            )
        return Flags.Management(
            // nil lets `containerConfigFromFlags` infer os/arch from the image's index, as the
            // 1.6.1 CLI does (apple/container#2422): an amd64-only image then runs under Rosetta
            // instead of failing "does not support linux/arm64", and a multi-platform image still
            // resolves to the host (or CONTAINER_DEFAULT_PLATFORM). The Platform field still wins.
            arch: nil,
            capAdd: options.capAdd,
            capDrop: options.capDrop,
            cidfile: nilIfEmpty(options.cidFile) ?? "",
            detach: !options.attach,
            dns: dns,
            dnsDisabled: options.noDns,
            entrypoint: nilIfEmpty(options.entrypoint),
            initImage: nil,
            kernel: nil,
            kernelArgs: options.kernelArgs,
            labels: options.labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            // maskedPaths/readonlyPaths (1.2.1, EXPERIMENTAL upstream) have no Berthly UI yet —
            // empty means "use the runtime defaults" (see PARITY.md's Deliberate gaps).
            maskedPaths: [],
            mounts: options.mounts,
            name: nilIfEmpty(options.name),
            networks: options.networks,
            os: nil,
            platform: nilIfEmpty(options.platform),
            publishPorts: options.ports,
            publishSockets: [],
            readOnly: options.readOnly,
            readonlyPaths: [],
            remove: options.remove,
            rosetta: options.rosetta,
            runtime: nil,
            ssh: options.ssh,
            shmSize: nilIfEmpty(options.shmSize),
            tmpFs: options.tmpfs,
            useInit: options.initProcess,
            virtualization: options.virtualization,
            volumes: options.volumes
        )
    }

    nonisolated static func runResourceFlags(for options: RunOptions) -> Flags.Resource {
        Flags.Resource(cpus: options.cpus.map { Int64($0) }, memory: nilIfEmpty(options.memory))
    }

    nonisolated static func runRegistryFlags(for options: RunOptions) -> Flags.Registry {
        // apple/container#2100 removed the "auto" scheme. This one string fans out to both the
        // app-image and init-image fetches inside `containerConfigFromFlags`, so per-host
        // detection isn't safe here — the insecure toggle keeps its "force http" meaning and
        // everything else is https. A run against an untoggled internal-registry image now needs
        // the toggle (RegistrySchemeResolver still covers the single-host pull/push/recreate paths).
        Flags.Registry(scheme: options.insecureRegistry ? "http" : "https")
    }

    nonisolated static func writeCIDFile(_ id: String, to path: String) throws {
        try writeOwnerOnlyData(Data(id.utf8), to: URL(fileURLWithPath: path), replaceExisting: false)
    }

    /// Native (XPC API, no CLI shelling) implementation of `container run`/`container create`.
    /// Reuses the vendored package's own `Utility.containerConfigFromFlags` — the same image
    /// fetch/unpack, kernel resolution, volume/network/DNS resolution the CLI itself runs — so
    /// this doesn't have to reimplement any of that. `start == false` stops after `create`
    /// (left provisioned, not bootstrapped). `start && !attach` bootstraps and starts detached.
    /// `start && attach` captures the container's own stdout via our own pipe and waits for exit
    /// — for one-shot commands like `pwd`. This app never attaches an interactive terminal.
    func runContainerImpl(options: RunOptions, onLog: (@MainActor (String) -> Void)?) async throws -> String {
        let id = Utility.createContainerID(name: options.name)
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }

        let client = ContainerClient()
        if (try? await client.get(id: id)) != nil {
            throw ContainerCLIError(exitCode: 1, message: "A container named \"\(id)\" already exists.")
        }

        let containerSystemConfig = await resolvedSystemConfig()
        // Fetching, not just unpacking, is the slow part (a first boot needing a fresh kernel or
        // vminit image can take minutes) — `.setDescription` events distinguish those stages from
        // whatever DownloadReporter's caller-supplied label would otherwise say.
        let reporter = onLog.map { onLog in
            DownloadReporter(label: "Fetching image", onLog: onLog)
        }
        let (containerConfig, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: id,
            image: options.reference,
            arguments: options.command,
            process: Self.runProcessFlags(for: options),
            management: Self.runManagementFlags(for: options),
            resource: Self.runResourceFlags(for: options),
            registry: Self.runRegistryFlags(for: options),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: reporter?.handler ?? Self.noopProgressHandler,
            log: Self.log
        )

        let createOptions = ContainerCreateOptions(autoRemove: options.remove)
        try await client.create(configuration: containerConfig, options: createOptions, kernel: kernel, initImage: initImage)

        if options.insecureRegistry, let host = ImageStaleness.registryHost(for: options.reference) {
            Self.rememberInsecureHost(host)
        }

        if let cidFile = options.cidFile, !cidFile.isEmpty {
            do {
                try Self.writeCIDFile(id, to: cidFile)
            } catch {
                try? await client.delete(id: id, force: true)
                throw error
            }
        }

        guard options.start else {
            await refresh()
            return ""
        }

        do {
            if !options.attach {
                let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                try await process.start()
                await refresh()
                return ""
            }

            // `bootstrap` (like `createProcess`) closes every stdio fd it receives — `XPCMessage`'s
            // fd setter takes ownership. So hand it write ends wrapped non-owning
            // (`closeOnDealloc: false`) and never retain a `Pipe` that would close the same fd a
            // second time: a stale double-close lands on a since-reused descriptor (in the field, a
            // freshly-fetched container-log fd → EBADF). See `TerminalSession.makeExecPipe`.
            // stdout and stderr merge into one pipe, but each slot needs its OWN fd (the library
            // closes each), so `dup` a second write end rather than passing one handle twice.
            var fds = [Int32](repeating: -1, count: 2)
            guard pipe(&fds) == 0 else {
                throw ContainerizationError(.internalError, message: "pipe() failed (errno \(errno))")
            }
            let stderrFd = dup(fds[1])
            guard stderrFd >= 0 else {
                close(fds[0]); close(fds[1])
                throw ContainerizationError(.internalError, message: "dup() failed (errno \(errno))")
            }
            let readEnd = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            let stdoutEnd = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
            let stderrEnd = FileHandle(fileDescriptor: stderrFd, closeOnDealloc: false)
            let process = try await client.bootstrap(id: id, stdio: [nil, stdoutEnd, stderrEnd])
            try await process.start()
            // No manual close needed: the daemon closed both write ends, so our `readEnd` sees EOF
            // once the process exits. `readEnd` owns its fd and is closed when this scope releases it.

            let (exitCode, output) = try await withTaskCancellationHandler {
                async let waitResult = process.wait()
                let capturedOutput: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = readEnd.readDataToEndOfFile()
                        cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    }
                }
                return (try await waitResult, capturedOutput)
            } onCancel: {
                Task { try? await process.kill(SIGTERM) }
            }

            // A cancelled run kills the process via SIGTERM above, which makes `process.wait()`
            // return a real (non-zero) exit code rather than throwing — check cancellation
            // explicitly so this surfaces as `CancellationError` (caught below, cleaned up, and
            // recognized by callers as "the user cancelled") instead of a misleading
            // "command failed" `ContainerCLIError`.
            try Task.checkCancellation()

            await refresh()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if exitCode != 0 {
                throw ContainerCLIError(exitCode: exitCode, message: trimmed)
            }
            return trimmed
        } catch let cliError as ContainerCLIError {
            // A non-zero exit is a normal outcome, not an infra failure — the container ran and
            // already exited on its own, so leave it in place (matching the CLI's own behavior)
            // rather than deleting it.
            throw cliError
        } catch {
            try? await client.delete(id: id, force: true)
            throw error
        }
    }
}
