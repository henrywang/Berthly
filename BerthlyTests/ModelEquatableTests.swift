// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

/// Regression guard for a real bug: several resource models define a custom `Equatable`
/// comparing only `id`, which SwiftUI's `ForEach` uses to skip re-rendering elements it considers
/// unchanged — so a row whose *rendered* field changes while its id stays put never redraws.
/// `Builder`'s status flip (Stop/Start) was found stuck this way; the fix widened its `==` to
/// include `status`, matching `Container`/`Machine`'s existing precedent. This file locks in that
/// every model with a custom `==` includes whatever field it actually renders per row, so the same
/// bug can't quietly return to any of them — a UI reproduction needs a live interaction that
/// mutates the field without navigating away (the exact thing that "fixes" the display and masks
/// a regression), which is fragile and slow next to a direct equality check.
struct ModelEquatableTests {

    @Test func containerInequalityOnStatusChange() {
        let running = Container(
            id: "c1", name: "web", image: "local/web:1.0", status: .running, ports: [],
            cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "-", uptime: "-",
            command: "", mounts: [], networks: [], environment: []
        )
        let stoppedStatus = Container(
            id: "c1", name: "web", image: "local/web:1.0", status: .stopped, ports: [],
            cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "-", uptime: "-",
            command: "", mounts: [], networks: [], environment: []
        )
        #expect(running != stoppedStatus, "same id, different status must compare unequal")
    }

    @Test func containerInequalityOnImageChange() {
        let a = Container(
            id: "c1", name: "web", image: "local/web:1.0", status: .running, ports: [],
            cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "-", uptime: "-",
            command: "", mounts: [], networks: [], environment: []
        )
        let b = Container(
            id: "c1", name: "web", image: "local/web:2.0", status: .running, ports: [],
            cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "-", uptime: "-",
            command: "", mounts: [], networks: [], environment: []
        )
        #expect(a != b, "same id, different image must compare unequal (late-arriving image data)")
    }

    @Test func machineInequalityOnStatusChange() {
        let running = Machine(
            id: "m1", name: "dev", image: "debian:12", status: .running, isUtility: false,
            diskUsedGB: 0, diskTotalGB: 0, uptimeString: "-", kernel: "-", resources: "-",
            created: "-", homeMount: .none
        )
        let stopped = Machine(
            id: "m1", name: "dev", image: "debian:12", status: .stopped, isUtility: false,
            diskUsedGB: 0, diskTotalGB: 0, uptimeString: "-", kernel: "-", resources: "-",
            created: "-", homeMount: .none
        )
        #expect(running != stopped, "same id, different status must compare unequal")
    }

    @Test func machineInequalityOnDefaultBadgeChange() {
        let notDefault = Machine(
            id: "m1", name: "dev", image: "debian:12", status: .running, isUtility: false,
            diskUsedGB: 0, diskTotalGB: 0, uptimeString: "-", kernel: "-", resources: "-",
            created: "-", homeMount: .none, isDefault: false
        )
        let isDefault = Machine(
            id: "m1", name: "dev", image: "debian:12", status: .running, isUtility: false,
            diskUsedGB: 0, diskTotalGB: 0, uptimeString: "-", kernel: "-", resources: "-",
            created: "-", homeMount: .none, isDefault: true
        )
        #expect(notDefault != isDefault, "same id, different isDefault must compare unequal (Set as Default)")
    }

    @Test func builderInequalityOnStatusChange() {
        let running = Builder(id: "default", name: "default", image: "buildkit:0.13", status: .running,
                               autoStarted: true, cpus: 2, memoryGB: 2)
        let stopped = Builder(id: "default", name: "default", image: "buildkit:0.13", status: .stopped,
                               autoStarted: true, cpus: 2, memoryGB: 2)
        #expect(running != stopped, "same id, different status must compare unequal — the bug this file guards")
    }

    @Test func networkInequalityOnEndpointsChange() {
        let empty = Network(
            id: "n1", name: "app-net", driver: .nat, subnet: "10.0.0.0/24", gateway: "10.0.0.1",
            isDefault: false, scope: "local", ipv6Enabled: false, egress: "", attachable: true,
            backend: "vmnet", endpoints: []
        )
        let attached = Network(
            id: "n1", name: "app-net", driver: .nat, subnet: "10.0.0.0/24", gateway: "10.0.0.1",
            isDefault: false, scope: "local", ipv6Enabled: false, egress: "", attachable: true,
            backend: "vmnet",
            endpoints: [NetworkEndpoint(id: "e1", name: "web", ipv4: "10.0.0.2", kind: "CONTAINER",
                                        isRunning: true, aliases: [])]
        )
        #expect(empty != attached, "same id, different endpoints must compare unequal (attach/detach)")
    }

    @Test func volumeInequalityOnMountsChange() {
        let unmounted = Volume(
            id: "v1", name: "pgdata", type: .named, usedMB: 100, allocatedMB: 0, driver: "local",
            source: "", created: "-", labels: [], mounts: [], fs: "ext4", reclaimable: true
        )
        let mounted = Volume(
            id: "v1", name: "pgdata", type: .named, usedMB: 100, allocatedMB: 0, driver: "local",
            source: "", created: "-", labels: [],
            mounts: [VolumeMount(containerName: "datastore", mountPath: "/data", mode: "RW")],
            fs: "ext4", reclaimable: false
        )
        #expect(unmounted != mounted, "same id, different mounts must compare unequal (mount/unmount)")
    }

    @Test func containerImageInequalityOnUsageChange() {
        let unused = ContainerImage(
            id: "local/web:1.4", repository: "local/web", tag: "1.4", digest: "sha256:abc",
            arch: ["arm64"], sizeBytes: 0, created: "-", source: .pulled, usage: .unused
        )
        let used = ContainerImage(
            id: "local/web:1.4", repository: "local/web", tag: "1.4", digest: "sha256:abc",
            arch: ["arm64"], sizeBytes: 0, created: "-", source: .pulled, usage: .usedBy(1)
        )
        #expect(unused != used, "same id, different usage must compare unequal (UsageBadge redraw)")
    }
}
