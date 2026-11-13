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
    /// Stops the daemon, downloads the pinned signed installer, verifies Apple's identity before
    /// and after root-owned staging, then restarts. The upstream update script is deliberately not
    /// used because it selects a release asset by filename without enforcing the signing identity.
    /// Callers must confirm first because `stopDaemon()` stops every container on the machine.
    func upgradeContainerImpl(onLog: @MainActor @escaping (String) -> Void) async throws {
        await stopDaemon()
        guard case .installedButStopped = daemonState else {
            throw ContainerizationError(.invalidState, message: "Couldn't stop the container daemon before upgrading.")
        }

        do {
            try await installSignedContainerPackage(
                version: ContainerCompatibility.requiredVersion,
                onLog: onLog
            )
        } catch {
            // Put the daemon back the way we found it — the user should land on a running
            // (still-old) setup, not stranded on the stopped gate. Unstructured Task so a
            // cancelled operation can't suppress the restart.
            Task { await self.startDaemon() }
            throw error
        }

        await startDaemon(onLog: onLog)
    }

    /// First-time install uses the same pinned, double-verified package path as an upgrade.
    /// `startDaemon()` afterwards bootstraps the default kernel, so a fresh Mac goes straight to
    /// a working setup.
    func installContainerImpl(onLog: @MainActor @escaping (String) -> Void) async throws {
        try await installSignedContainerPackage(
            version: ContainerCompatibility.requiredVersion,
            onLog: onLog
        )
        onLog("Starting container system…")
        await startDaemon(onLog: onLog)
    }

    private func installSignedContainerPackage(
        version: String,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        let pkgName = "container-\(version)-installer-signed.pkg"
        let url = URL(string: "https://github.com/apple/container/releases/download/\(version)/\(pkgName)")!

        onLog("Downloading \(pkgName)…")
        let pkgPath = try await Self.downloadFile(from: url, suggestedName: pkgName)
        defer { try? FileManager.default.removeItem(atPath: pkgPath) }
        onLog("Downloaded to \(pkgPath)")

        onLog("Verifying package signature…")
        try await Self.verifyPackageSignature(at: pkgPath)
        onLog("Signature OK (signed by Apple)")

        try await runPrivilegedShellCommand(
            Self.stagedInstallCommand(pkgPath: pkgPath),
            onLog: onLog
        )
    }

    private nonisolated static func downloadFile(from url: URL, suggestedName: String) async throws -> String {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ContainerizationError(
                .internalError,
                message: "Download failed (HTTP \(http.statusCode)) for \(url.absoluteString)"
            )
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination.path
    }

    /// The leaf-certificate identity `pkgutil --check-signature` prints for apple/container release
    /// pkgs, with Apple's Containerization team ID (verified against the signed 1.2.0 pkg). Not the
    /// generic "signed by a developer certificate issued by Apple" line, which every Developer ID
    /// matches. If upstream rotates its identity, installs fail closed until this is re-pinned
    /// (re-check on `ContainerCompatibility.requiredVersion` bumps).
    nonisolated static let appleSignatureMarkers = [
        "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)"
    ]

    /// The acceptance predicate for `pkgutil --check-signature`, extracted pure so the
    /// security-critical decision is testable without spawning a process.
    nonisolated static func isAcceptableSignature(output: String, terminationStatus: Int32) -> Bool {
        terminationStatus == 0 && appleSignatureMarkers.contains { output.contains($0) }
    }

    /// Refuses to hand a pkg to the elevated installer unless `pkgutil` confirms it's signed by
    /// Apple itself — a hijacked download (or a truncated file) must fail here, before the admin
    /// prompt.
    private nonisolated static func verifyPackageSignature(at pkgPath: String) async throws {
        let (status, output) = try await runProcessCollectingOutput(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", pkgPath]
        )
        guard isAcceptableSignature(output: output, terminationStatus: status) else {
            throw ContainerizationError(
                .internalError,
                message: "The downloaded installer package failed signature verification — refusing to install it.\n\(output)"
            )
        }
    }

    /// Runs a short command to completion without blocking a cooperative-pool thread — the
    /// blocking drain happens inside `terminationHandler`, which fires on Process's own private
    /// queue. Only for commands whose output fits the pipe buffer (~64 KB): a chattier command
    /// would fill the pipe and never exit. `pkgutil --check-signature` prints a few hundred bytes.
    private nonisolated static func runProcessCollectingOutput(
        executablePath: String,
        arguments: [String]
    ) async throws -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Shell-quotes a value for safe interpolation into an `sh` command: wrapped in single
    /// quotes, embedded single quotes spliced out as `'\''`.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The elevated install command. The user-space signature check runs before the password prompt,
    /// but that pkg sits in a user-writable temp dir and could be swapped before the root install.
    /// So the elevated shell copies it into a root-owned staging dir (mode 700 under sticky /tmp),
    /// re-verifies the copy, and installs exactly that copy.
    nonisolated static func stagedInstallCommand(pkgPath: String) -> String {
        let grepMarkers = appleSignatureMarkers.map { "-e \(shellQuoted($0))" }.joined(separator: " ")
        // The signature is captured into a variable rather than piped straight into `grep` —
        // `sig=$(pkgutil ...)` preserves pkgutil's own exit status on the assignment, whereas
        // `pkgutil ... | grep ...` would report grep's exit status instead, letting a failing
        // pkgutil silently pass if its partial output happened to still match.
        return "staging=$(/usr/bin/mktemp -d /tmp/berthly-install.XXXXXX)"
            + " && /bin/cp \(shellQuoted(pkgPath)) \"$staging/container.pkg\""
            + " && sig=$(/usr/sbin/pkgutil --check-signature \"$staging/container.pkg\")"
            + " && echo \"$sig\" | /usr/bin/grep \(grepMarkers)"
            + " && /usr/sbin/installer -pkg \"$staging/container.pkg\" -target /"
            + "; status=$?; /bin/rm -rf \"$staging\"; exit $status"
    }

    /// AppleScript source for an elevated shell command. Backslashes and double quotes are escaped so
    /// a quoted path can't end the string literal early. The fixed system-only PATH means a writable
    /// package-manager directory can never provide a root command; any other executable is invoked
    /// by absolute path after its ownership and signature are checked.
    nonisolated static func privilegedAppleScript(for shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"export PATH=/usr/bin:/bin:/usr/sbin:/sbin; \(escaped)\" with administrator privileges"
    }

    /// `osascript` reports a dismissed admin-password dialog as `execution error: User canceled.
    /// (-128)` with exit code 1, same as a real failure. The message is localized, so only the
    /// trailing code is matched, anchored to the line end (after trimming trailing whitespace some
    /// locales append) so output that merely mentions -128 can't mask a real failure.
    nonisolated static func userCancelledAdminPrompt(_ outputLines: [String]) -> Bool {
        outputLines.contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("(-128)") }
    }

    /// Error text for a failed elevated command: the output tail is almost always more useful
    /// than the exit code, so include it when there is any.
    nonisolated static func privilegedFailureMessage(exitCode: Int32, outputLines: [String]) -> String {
        let tail = outputLines.suffix(6).joined(separator: "\n")
        if tail.isEmpty {
            return "The elevated command failed (exit code \(exitCode)) and produced no output."
        }
        return "The elevated command failed (exit code \(exitCode)):\n\(tail)"
    }

    /// Runs a shell command elevated via `osascript ... with administrator privileges` (the native
    /// admin-password dialog). The process is tracked in `privilegedProcess` and killed on task
    /// cancellation and app quit: an orphaned osascript sits on its dialog forever and blocks every
    /// later authorization prompt on the system. A dismissed dialog throws `CancellationError`.
    private func runPrivilegedShellCommand(
        _ shellCommand: String,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        let appleScript = Self.privilegedAppleScript(for: shellCommand)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let readHandle = pipe.fileHandleForReading
        let drainTask = Task.detached(priority: .userInitiated) { () -> [String] in
            var collected: [String] = []
            while true {
                let data = readHandle.availableData
                if data.isEmpty { return collected }
                guard let str = String(data: data, encoding: .utf8) else { continue }
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    collected.append(line)
                    await MainActor.run { onLog(line) }
                }
            }
        }

        privilegedProcess = process
        defer { privilegedProcess = nil }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { finishedProcess in
                        Task {
                            let outputLines = await drainTask.value
                            if finishedProcess.terminationStatus == 0 {
                                continuation.resume()
                            } else if Self.userCancelledAdminPrompt(outputLines) {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: ContainerizationError(
                                    .internalError,
                                    message: Self.privilegedFailureMessage(
                                        exitCode: finishedProcess.terminationStatus,
                                        outputLines: outputLines
                                    )
                                ))
                            }
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                // isRunning guards the never-launched case (terminate() would raise); a process
                // that already exited ignores the extra SIGTERM.
                if process.isRunning { process.terminate() }
            }
        } catch {
            // A SIGTERM from cancellation surfaces as a nonzero exit — report it as the
            // cancellation it is, not as a failure.
            try Task.checkCancellation()
            throw error
        }
    }
}
