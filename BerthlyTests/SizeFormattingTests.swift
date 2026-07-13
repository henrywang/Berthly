import Foundation
import Testing
@testable import Berthly

struct DeleteWarningTests {

    private func image(usage: ImageUsage) -> ContainerImage {
        ContainerImage(id: "abc", repository: "local/web", tag: "1", arch: ["arm64"],
                       sizeBytes: 1_048_576, created: "now", source: .built, usage: usage)
    }

    private func volume(mounts: [VolumeMount]) -> Volume {
        Volume(id: "v", name: "data", type: .named, usedMB: 10, allocatedMB: 256,
               driver: "local", source: "", created: "now", labels: [], mounts: mounts,
               fs: "ext4", reclaimable: false)
    }

    @Test func imageWarningReflectsUsageAndPluralizes() {
        #expect(String(localized: image(usage: .unused).deleteWarning) == "This will remove the image from local storage.")
        #expect(String(localized: image(usage: .usedBy(1)).deleteWarning)
            == "This image is used by 1 container. Deleting it may affect those containers.")
        #expect(String(localized: image(usage: .usedBy(3)).deleteWarning)
            == "This image is used by 3 containers. Deleting it may affect those containers.")
    }

    @Test func volumeWarningReflectsMountsAndPluralizes() {
        #expect(String(localized: volume(mounts: []).deleteWarning) == "This will permanently delete the volume and all its data.")
        let one = [VolumeMount(containerName: "a", mountPath: "/x", mode: "RW")]
        #expect(String(localized: volume(mounts: one).deleteWarning)
            == "This volume is mounted by 1 container. Deleting it may cause data loss.")
        let two = one + [VolumeMount(containerName: "b", mountPath: "/y", mode: "RW")]
        #expect(String(localized: volume(mounts: two).deleteWarning)
            == "This volume is mounted by 2 containers. Deleting it may cause data loss.")
    }
}

struct SizeFormattingTests {

    @Test func formatSizePicksLargestUnitAtOrAboveOne() {
        #expect(formatSize(0) == "0 B")
        #expect(formatSize(512) == "512 B")
        #expect(formatSize(1_024) == "1 KB")
        #expect(formatSize(1_048_576) == "1 MB")
        #expect(formatSize(5 * 1_048_576) == "5 MB")
        #expect(formatSize(1_073_741_824) == "1.0 GB")           // 1 GiB
        #expect(formatSize(3 * 1_073_741_824 / 2) == "1.5 GB")   // 1.5 GiB
    }

    @Test func formatVolumeMBCrossesToGigabytesAtOneThousandTwentyFour() {
        #expect(formatVolumeMB(0) == "0 MB")
        #expect(formatVolumeMB(512) == "512 MB")
        #expect(formatVolumeMB(1_023) == "1023 MB")
        #expect(formatVolumeMB(1_024) == "1.0 GB")
        #expect(formatVolumeMB(1_536) == "1.5 GB")
    }
}
