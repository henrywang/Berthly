// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

enum MockDataset: Equatable {
    case `default`
    case large
}

extension MockContainerService {
    func applyLargeFixture() {
        let fixture = LargeMockFixture.make()
        containers = fixture.containers
        images = fixture.images
        volumes = fixture.volumes
        networks = fixture.networks
        machines = fixture.machines
        imageUpdateInfo = [:]
        lastImageUpdateCheck = nil
        imageInspectData = [:]
        buildContexts = [:]
    }
}

struct LargeMockFixture: Equatable {
    let containers: [Container]
    let images: [ContainerImage]
    let volumes: [Volume]
    let networks: [Network]
    let machines: [Machine]

    static func make() -> LargeMockFixture {
        let containers = makeContainers()
        let machines = makeMachines()
        let images = ContainerImage.resolvingUsage(
            makeImages(),
            containers: containers,
            machines: machines
        )
        let volumes = Volume.resolvingMounts(makeVolumes(), containers: containers)
        let networks = makeNetworks(containers: containers, machines: machines)
        return LargeMockFixture(
            containers: containers,
            images: images,
            volumes: volumes,
            networks: networks,
            machines: machines
        )
    }

    private static func makeContainers() -> [Container] {
        let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)
        return (0..<100).map { index in
            let status = containerStatus(index)
            let volumeIndex = index.isMultiple(of: 3) ? index % 30 : nil
            let mounts = volumeIndex.map {
                [ContainerMount(
                    source: volumeName($0),
                    destination: "/data/\(padded(index))",
                    volumeName: volumeName($0),
                    isReadOnly: index.isMultiple(of: 6)
                )]
            } ?? []
            return Container(
                id: containerName(index),
                name: containerName(index),
                image: imageReference(index % 40),
                imageDigest: imageDigest(index % 40),
                status: status,
                ports: index.isMultiple(of: 5)
                    ? [PortMapping(host: 10_000 + index, container: 8_000)]
                    : [],
                cpuPercent: status == .running ? Double((index * 7) % 80) + 0.5 : 0,
                memoryMB: status == .running ? 64 + (index % 8) * 32 : 0,
                memoryLimitMB: 512 + (index % 4) * 256,
                networkIOString: status == .running ? "\(index + 1) KB/s" : "–",
                uptime: status == .running ? "\(index + 1)m" : "–",
                command: index == 42
                    ? "/usr/local/bin/large-inventory-worker --queue=events --concurrency=16"
                    : "sleep 3600",
                mounts: mounts,
                networks: containerNetworks(index),
                environment: ["BERTHLY_FIXTURE_INDEX=\(index)"],
                startedDate: status == .running
                    ? referenceDate.addingTimeInterval(TimeInterval(-index * 60))
                    : nil
            )
        }
    }

    private static func makeMachines() -> [Machine] {
        (0..<20).map { index in
            let cpus = 1 + index % 4
            let memoryGB = 1 + index % 8
            return Machine(
                id: machineName(index),
                name: machineName(index),
                image: imageReference(40 + index % 5),
                status: index < 12 ? .running : .stopped,
                isUtility: index == 19,
                diskUsedGB: Double(index + 1) * 0.25,
                diskTotalGB: 8,
                uptimeString: index < 12 ? "\(index + 1)h" : "–",
                kernel: "6.12.4-arm64",
                resources: "\(cpus) vCPU · \(memoryGB) GB",
                created: "2026-01-01",
                homeMount: machineHomeMount(index),
                isDefault: index == 0
            )
        }
    }

    private static func makeImages() -> [ContainerImage] {
        (0..<50).map { index in
            let repository = index == 49
                ? "registry.example.internal/berthly/large-inventory/unused-diagnostic-image"
                : "local/fixture-image-\(padded(index))"
            return ContainerImage(
                id: "\(repository):v1",
                repository: repository,
                tag: "v1",
                digest: imageDigest(index),
                arch: index.isMultiple(of: 4) ? ["arm64", "amd64"] : ["arm64"],
                sizeBytes: Int64(32 + index * 3) * 1_048_576,
                created: "2026-01-01",
                source: index.isMultiple(of: 2) ? .built : .pulled,
                usage: .unused
            )
        }
    }

    private static func makeVolumes() -> [Volume] {
        (0..<40).map { index in
            let name = volumeName(index)
            return Volume(
                id: name,
                name: name,
                type: index < 30 ? .named : .anonymous,
                usedMB: 16 + index * 8,
                allocatedMB: 1_024,
                driver: "local",
                source: "/mock/volumes/\(name)/volume.img",
                created: "2026-01-01",
                labels: ["berthly.fixture=large"],
                options: ["size=1G"],
                mounts: [],
                fs: "ext4",
                reclaimable: true
            )
        }
    }

    private static func makeNetworks(containers: [Container], machines: [Machine]) -> [Network] {
        (0..<20).map { index in
            let id = networkName(index)
            let containerEndpoints = containers
                .filter { $0.networks.contains(id) }
                .enumerated()
                .map { offset, container in
                    NetworkEndpoint(
                        id: "endpoint-\(container.id)-\(id)",
                        name: container.name,
                        ipv4: "10.\(index + 20).0.\(offset + 10)",
                        kind: "CONTAINER",
                        isRunning: container.status == .running,
                        aliases: [container.name]
                    )
                }
            var machineEndpoints: [NetworkEndpoint] = []
            if index < 10 {
                let machine = machines[index]
                machineEndpoints.append(NetworkEndpoint(
                    id: "endpoint-\(machine.id)-\(id)",
                    name: machine.name,
                    ipv4: "10.\(index + 20).0.200",
                    kind: "MACHINE",
                    isRunning: machine.status == .running,
                    aliases: [machine.name]
                ))
            }
            return Network(
                id: id,
                name: id,
                driver: index.isMultiple(of: 3) ? .hostOnly : .nat,
                subnet: "10.\(index + 20).0.0/24",
                gateway: "10.\(index + 20).0.1",
                isDefault: index == 0,
                scope: "local",
                ipv6Enabled: index.isMultiple(of: 5),
                egress: index.isMultiple(of: 3) ? "" : "NAT → en0",
                attachable: true,
                backend: "vmnet",
                endpoints: containerEndpoints + machineEndpoints
            )
        }
    }

    private static func containerStatus(_ index: Int) -> ContainerStatus {
        switch index % 10 {
        case 0...5: .running
        case 6...7: .stopped
        case 8: .paused
        default: .error
        }
    }

    private static func containerNetworks(_ index: Int) -> [String] {
        guard !index.isMultiple(of: 10) else { return [] }
        let primary = networkName(index % 20)
        guard index.isMultiple(of: 4) else { return [primary] }
        return [primary, networkName((index + 1) % 20)]
    }

    private static func machineHomeMount(_ index: Int) -> MachineHomeMount {
        switch index % 3 {
        case 0: .readWrite
        case 1: .readOnly
        default: .none
        }
    }

    private static func containerName(_ index: Int) -> String { "container-\(padded(index))" }
    private static func machineName(_ index: Int) -> String { "machine-\(padded(index))" }
    private static func volumeName(_ index: Int) -> String { "volume-\(padded(index))" }
    private static func networkName(_ index: Int) -> String { "network-\(padded(index))" }
    private static func imageDigest(_ index: Int) -> String { "sha256:fixture\(padded(index))" }

    private static func imageReference(_ index: Int) -> String {
        "local/fixture-image-\(padded(index)):v1"
    }

    private static func padded(_ index: Int) -> String {
        String(format: "%03d", index)
    }
}
