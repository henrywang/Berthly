// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

@MainActor
struct LargeMockFixtureTests {

    @Test func generatesExpectedInventory() {
        let fixture = LargeMockFixture.make()

        #expect(fixture.containers.count == 100)
        #expect(fixture.machines.count == 20)
        #expect(fixture.images.count == 50)
        #expect(fixture.volumes.count == 40)
        #expect(fixture.networks.count == 20)
        #expect(fixture.containers.first?.id == "container-000")
        #expect(fixture.containers.last?.id == "container-099")
        #expect(fixture.machines.first?.id == "machine-000")
        #expect(fixture.machines.last?.id == "machine-019")
    }

    @Test func generatesUniqueResourceIdentities() {
        let fixture = LargeMockFixture.make()

        #expect(Set(fixture.containers.map(\.id)).count == fixture.containers.count)
        #expect(Set(fixture.containers.map(\.name)).count == fixture.containers.count)
        #expect(Set(fixture.machines.map(\.id)).count == fixture.machines.count)
        #expect(Set(fixture.machines.map(\.name)).count == fixture.machines.count)
        #expect(Set(fixture.images.map(\.id)).count == fixture.images.count)
        #expect(Set(fixture.volumes.map(\.id)).count == fixture.volumes.count)
        #expect(Set(fixture.networks.map(\.id)).count == fixture.networks.count)
    }

    @Test func includesExpectedStatesAndEdgeCases() {
        let fixture = LargeMockFixture.make()

        #expect(fixture.containers.count { $0.status == .running } == 60)
        #expect(fixture.containers.count { $0.status == .stopped } == 20)
        #expect(fixture.containers.count { $0.status == .paused } == 10)
        #expect(fixture.containers.count { $0.status == .error } == 10)
        #expect(fixture.machines.count { $0.status == .running } == 12)
        #expect(fixture.machines.count { $0.status == .stopped } == 8)
        #expect(fixture.machines.count { $0.isUtility } == 1)
        #expect(fixture.machines.count { $0.isDefault } == 1)
        #expect(fixture.containers.contains { $0.networks.isEmpty })
        #expect(fixture.containers.contains { $0.networks.count > 1 })
        #expect(fixture.volumes.contains { $0.mounts.isEmpty })
        #expect(fixture.volumes.contains { !$0.mounts.isEmpty })
        #expect(fixture.networks.contains { $0.driver == .nat })
        #expect(fixture.networks.contains { $0.driver == .hostOnly })
        #expect(fixture.images.contains { $0.fullName.count > 70 })
        #expect(fixture.images.contains { $0.usage == .unused })
        #expect(fixture.images.contains {
            if case .usedBy = $0.usage { return true }
            return false
        })
    }

    @Test func resolvesEveryImageReference() {
        let fixture = LargeMockFixture.make()
        let images = fixture.images

        for reference in fixture.containers.map(\.image) + fixture.machines.map(\.image) {
            #expect(images.contains { image in
                reference == image.id || reference == image.fullName || reference == image.digest
            })
        }
    }

    @Test func derivesVolumeMountsFromContainers() throws {
        let fixture = LargeMockFixture.make()

        for volume in fixture.volumes {
            let expected = fixture.containers.flatMap { container in
                container.mounts
                    .filter { $0.volumeName == volume.name }
                    .map { VolumeMount(
                        containerName: container.name,
                        mountPath: $0.destination,
                        mode: $0.isReadOnly ? "RO" : "RW"
                    ) }
            }
            #expect(volume.mounts == expected)
            #expect(volume.reclaimable == volume.mounts.isEmpty)
        }

        for container in fixture.containers {
            for mount in container.mounts {
                let volumeName = try #require(mount.volumeName)
                #expect(fixture.volumes.contains { $0.name == volumeName })
            }
        }
    }

    @Test func keepsNetworkAttachmentsAndEndpointsConsistent() {
        let fixture = LargeMockFixture.make()

        for container in fixture.containers {
            for networkID in container.networks {
                let network = fixture.networks.first { $0.id == networkID }
                #expect(network != nil)
                #expect(network?.endpoints.contains {
                    $0.kind == "CONTAINER" && $0.name == container.name
                } == true)
            }
        }

        for network in fixture.networks {
            for endpoint in network.endpoints where endpoint.kind == "CONTAINER" {
                let container = fixture.containers.first { $0.name == endpoint.name }
                #expect(container?.networks.contains(network.id) == true)
            }
            for endpoint in network.endpoints where endpoint.kind == "MACHINE" {
                #expect(fixture.machines.contains { $0.name == endpoint.name })
            }
        }
    }

    @Test func generationIsDeterministic() {
        let first = LargeMockFixture.make()
        let second = LargeMockFixture.make()

        #expect(first == second)
    }
}
