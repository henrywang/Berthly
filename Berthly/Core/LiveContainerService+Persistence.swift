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
    func resolvedSystemConfig() async -> ContainerSystemConfig {
        if systemConfig == nil {
            let result: Result<ContainerSystemConfig, Error>
            do {
                result = .success(try await ConfigurationLoader.load())
            } catch {
                Self.log.error("failed to load system config", metadata: ["error": "\(error)"])
                result = .failure(error)
            }
            let (config, warning) = Self.mapSystemConfigLoadResult(result)
            systemConfig = config
            if let warning {
                lastStartupWarning = warning
            }
        }
        return systemConfig ?? ContainerSystemConfig()
    }

    /// `ConfigurationLoader.load()` only throws when a config file exists on disk but fails to
    /// parse or decode — it already returns cleanly with defaults when no file is present at all
    /// (`loadAndDecode`'s all-paths-missing short-circuit). So any caught error here means the
    /// user's actual customized `config.toml` is being discarded, not just "there was nothing to
    /// load" — worth a warning rather than a silent `try?` fallback to defaults.
    nonisolated static func mapSystemConfigLoadResult(
        _ result: Result<ContainerSystemConfig, Error>
    ) -> (config: ContainerSystemConfig, warning: String?) {
        switch result {
        case .success(let config):
            return (config, nil)
        case .failure(let error):
            return (
                ContainerSystemConfig(),
                "Couldn't load your container configuration, so Berthly is using defaults instead: \(error.localizedDescription)"
            )
        }
    }

    private static let contextsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Berthly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("build-contexts.json")
    }()

    private static let pinnedItemsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Berthly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pinned-items.json")
    }()

    func loadBuildContexts() {
        guard let data = try? Data(contentsOf: Self.contextsURL),
              let dict = try? JSONDecoder().decode([String: BuildContext].self, from: data) else { return }
        buildContexts = dict
    }

    func saveBuildContexts() {
        guard let data = try? JSONEncoder().encode(buildContexts) else { return }
        try? Self.writePrivateData(data, to: Self.contextsURL)
    }

    func loadPinnedItems() {
        guard let data = try? Data(contentsOf: Self.pinnedItemsURL),
              let items = try? JSONDecoder().decode(PinnedItems.self, from: data) else { return }
        pinnedContainerIDs = items.containers
        pinnedMachineIDs = items.machines
        pinnedContainerOrder = items.containerOrder ?? []
        pinnedMachineOrder = items.machineOrder ?? []
    }

    func savePinnedItems() {
        let items = PinnedItems(
            containers: pinnedContainerIDs, machines: pinnedMachineIDs,
            containerOrder: pinnedContainerOrder, machineOrder: pinnedMachineOrder)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? Self.writePrivateData(data, to: Self.pinnedItemsURL)
    }

    nonisolated static func writePrivateData(_ data: Data, to url: URL) throws {
        try writeOwnerOnlyData(data, to: url, replaceExisting: true)
    }

    nonisolated static func writeOwnerOnlyData(
        _ data: Data,
        to destination: URL,
        replaceExisting: Bool
    ) throws {
        let writeURL = replaceExisting
            ? destination.deletingLastPathComponent().appendingPathComponent(".berthly-\(UUID().uuidString).tmp")
            : destination
        let descriptor = open(writeURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(writeURL.path) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }

        if replaceExisting {
            guard rename(writeURL.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        shouldRemove = false
    }
}
