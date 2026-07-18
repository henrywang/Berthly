// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import MachineAPIClient

/// Bridges one exec'd shell session's PTY-backed stdio to byte callbacks a terminal view can
/// render, decoupling `Views/` from the exec transport (anonymous pipes handed to the daemon
/// over XPC) — the same insulation `ContainerServiceBase` gives the rest of the UI from
/// `LiveContainerService`.
///
/// Exec only ever detaches on close — it never kills the container, since the process may be
/// shared with other exec sessions or the container's own lifecycle (see PLAN.md §7.2).
@MainActor
final class TerminalSession {
    private(set) var isRunning = false

    /// Called with raw bytes read from the session's stdout as they arrive. Always invoked on
    /// the main actor — the underlying `FileHandle.readabilityHandler` fires on a background
    /// queue, so this hop is done for the caller rather than left implicit.
    var onOutput: ((Data) -> Void)?

    /// Called once the process exits, whether cleanly or via an I/O error.
    var onExit: ((Int32) -> Void)?

    // The two pipe ends this process keeps: the write end of stdin (we push keyboard/paste input
    // here) and the read end of stdout (we read container output here). The *other* two ends are
    // handed to the daemon by `createProcess`, which closes the fd it receives — so those handed-
    // off ends must not be closed a second time by us. See `makeExecPipe`.
    private var stdinWrite: FileHandle?
    private var stdoutRead: FileHandle?
    private var process: ClientProcess?

    /// Which end of a freshly-created OS pipe is handed to the daemon over XPC.
    enum HandOffEnd { case read, write }

    /// Pure fd-ownership policy for one exec pipe, split out from the `pipe()` syscall so it can be
    /// unit-tested without opening real descriptors — raw-fd juggling in-process under Swift
    /// Testing's parallel runner races on `FileHandle`'s non-deterministic deinit and crashes.
    ///
    /// The crux of the logs-`EBADF` fix lives in `handOffOwnsClose`. `createProcess` closes every
    /// stdio fd it receives (`XPCMessage.set(key:value:FileHandle)`), taking ownership of the
    /// handed-off end — so this side must *not* close it again. If the handed-off `FileHandle` also
    /// closed on release, the number — freed the instant the daemon closed it and promptly reused —
    /// would be clobbered by that second close; in practice the victim is a container-log fd fetched
    /// moments later over the same XPC channel, which then fails `readToEnd()` with `EBADF`. The
    /// kept end owns its fd normally.
    struct ExecPipePolicy: Equatable {
        /// The daemon reads the container's stdin (gets the read end) and writes its stdout (gets
        /// the write end); this process keeps the opposite end of each.
        let handOffIsReadEnd: Bool
        let handOffOwnsClose: Bool
        let keepOwnsClose: Bool

        nonisolated static func policy(handOff: HandOffEnd) -> ExecPipePolicy {
            // A `switch` rather than `handOff == .read`: `HandOffEnd`'s synthesized `Equatable` is
            // main-actor-isolated (the enum is nested in this `@MainActor` class), so comparing it
            // from this `nonisolated` context is a Swift 6 error.
            let handOffIsReadEnd: Bool
            switch handOff {
            case .read:  handOffIsReadEnd = true
            case .write: handOffIsReadEnd = false
            }
            return ExecPipePolicy(
                handOffIsReadEnd: handOffIsReadEnd,
                handOffOwnsClose: false,
                keepOwnsClose: true
            )
        }
    }

    /// Creates an OS pipe and splits it into the end handed to the daemon and the end this process
    /// keeps, per `ExecPipePolicy`, giving every fd unambiguous single-close ownership.
    nonisolated static func makeExecPipe(handOff: HandOffEnd) throws -> (handOff: FileHandle, keep: FileHandle) {
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            throw ContainerizationError(.internalError, message: "pipe() failed (errno \(errno))")
        }
        let readEnd = fds[0], writeEnd = fds[1]
        let policy = ExecPipePolicy.policy(handOff: handOff)
        let handOffFd = policy.handOffIsReadEnd ? readEnd : writeEnd
        let keepFd    = policy.handOffIsReadEnd ? writeEnd : readEnd
        return (
            handOff: FileHandle(fileDescriptor: handOffFd, closeOnDealloc: policy.handOffOwnsClose),
            keep: FileHandle(fileDescriptor: keepFd, closeOnDealloc: policy.keepOwnsClose)
        )
    }

    /// Starts an exec session into the given running container, trying
    /// `LiveContainerService.execShellCandidates` in order and using the first one that starts
    /// successfully.
    func start(containerID: String, shellCandidates: [String] = LiveContainerService.execShellCandidates) async throws {
        let client = ContainerClient()
        let snapshot = try await client.get(id: containerID)

        var lastError: Error = ContainerizationError(.internalError, message: "no shell candidates provided")
        for shell in shellCandidates {
            let config = LiveContainerService.execProcessConfiguration(basedOn: snapshot.configuration.initProcess, shell: shell)
            do {
                try await startProcess(containerId: containerID, configuration: config, client: client)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Starts a login shell in the container machine (VM), not a container — see PLAN.md §8.
    /// A machine's shell is itself just an exec'd process in the container backing the machine
    /// (`snapshot.containerId`), same `ContainerClient` as container exec; only how the target
    /// container and process configuration are resolved differs (see
    /// `LiveContainerService.machineShellProcessConfiguration(basedOn:)`).
    func start(machineID: String) async throws {
        let snapshot = try await MachineClient().inspect(id: machineID)
        guard let containerId = snapshot.containerId else {
            throw ContainerizationError(.invalidState, message: "container machine is running but has no container ID")
        }
        let config = LiveContainerService.machineShellProcessConfiguration(
            home: snapshot.configuration.home,
            user: snapshot.configuration.user
        )
        try await startProcess(containerId: containerId, configuration: config, client: ContainerClient())
    }

    private func startProcess(containerId: String, configuration: ProcessConfiguration, client: ContainerClient) async throws {
        // The daemon reads the container's stdin (so it gets the read end) and writes the
        // container's stdout (so it gets the write end); we keep the opposite end of each.
        let stdin = try Self.makeExecPipe(handOff: .read)
        let stdout = try Self.makeExecPipe(handOff: .write)
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: configuration,
            stdio: [stdin.handOff, stdout.handOff, nil]
        )
        try await proc.start()
        self.stdinWrite = stdin.keep
        self.stdoutRead = stdout.keep
        self.process = proc
        self.isRunning = true
        wireOutput(from: stdout.keep)
    }

    /// Feeds keyboard/paste input from the terminal view to the session's stdin.
    func send(_ data: Data) {
        try? stdinWrite?.write(contentsOf: data)
    }

    /// Propagates the terminal view's size so full-screen programs (`vim`, `htop`, `less`)
    /// render correctly instead of assuming a stale default size.
    func resize(cols: UInt16, rows: UInt16) async throws {
        try await process?.resize(Terminal.Size(width: cols, height: rows))
    }

    /// Detaches from the session — never kills the process, since it may be a shared container.
    func detach() {
        guard isRunning else { return }
        isRunning = false
        stdoutRead?.readabilityHandler = nil
        try? stdinWrite?.close()
        stdinWrite = nil
        stdoutRead = nil
    }

    private func wireOutput(from handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if data.isEmpty {
                    self.isRunning = false
                    handle.readabilityHandler = nil
                    self.onExit?(0)
                    return
                }
                self.onOutput?(data)
            }
        }
    }
}
