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

    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var process: ClientProcess?

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
        let stdin = Pipe()
        let stdout = Pipe()
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: configuration,
            stdio: [stdin.fileHandleForReading, stdout.fileHandleForWriting, nil]
        )
        try await proc.start()
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.process = proc
        self.isRunning = true
        wireOutput(from: stdout)
    }

    /// Feeds keyboard/paste input from the terminal view to the session's stdin.
    func send(_ data: Data) {
        try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
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
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        stdoutPipe = nil
    }

    private func wireOutput(from stdout: Pipe) {
        let handle = stdout.fileHandleForReading
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
