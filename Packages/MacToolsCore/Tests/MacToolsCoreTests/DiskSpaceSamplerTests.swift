import Foundation
import Testing

@testable import SysMetrics

/// The volume readings of this machine, and the arithmetic that lets a fast
/// pass leave the expensive half of "available" out.
@Suite("Disk space")
struct DiskSpaceSamplerTests {
    @Test("Every mounted volume has a capacity and a mount point")
    func sampleHasVolumes() {
        let volumes = DiskSpaceSampler.sample()
        #expect(!volumes.isEmpty)
        let boot = volumes.first { $0.isBootVolume }
        #expect(boot != nil)
        #expect(boot?.total ?? 0 > 0)
        #expect(boot?.mountPath == "/")
        // The boot volume sorts first, whatever else is mounted.
        #expect(volumes.first?.isBootVolume == true)
    }

    @Test("Without the purgeable key, available is the free blocks and nothing else")
    func cheapPassIsRawSpace() {
        for volume in DiskSpaceSampler.sample(includingPurgeableSpace: false) {
            #expect(volume.available == volume.availableRaw)
            #expect(volume.purgeableBonus == 0)
        }
    }

    @Test("The purgeable share is what the full pass has over the raw free space")
    func purgeableBonusIsTheDifference() {
        for volume in DiskSpaceSampler.sample() {
            #expect(
                volume.purgeableBonus
                    == Int64(bitPattern: volume.available) - Int64(bitPattern: volume.availableRaw)
            )
        }
    }

    @Test("A cheap pass with the bonus back on top is the full pass again")
    func bonusRestoresTheFullReading() {
        let full = DiskSpaceSampler.sample()
        let cheap = DiskSpaceSampler.sample(includingPurgeableSpace: false)
        for volume in full {
            guard let fast = cheap.first(where: { $0.mountPath == volume.mountPath }) else {
                continue
            }
            let restored = fast.addingPurgeableBonus(volume.purgeableBonus)
            // The free blocks move between the two reads on a live machine, so
            // the check is the arithmetic, not the byte.
            #expect(restored.available == fast.availableRaw + UInt64(max(0, volume.purgeableBonus)))
            #expect(restored.used == restored.total - restored.available)
        }
    }

    @Test("The bonus can never push available past the size of the disk")
    func bonusIsClamped() {
        let volume = VolumeInfo(
            name: "Test",
            mountPath: "/test",
            total: 1000,
            available: 400,
            availableRaw: 400,
            used: 600,
            isInternal: true,
            isRemovable: false,
            isBootVolume: false,
            fileSystemType: "apfs",
            device: "/dev/disk9s1"
        )
        #expect(volume.addingPurgeableBonus(10_000).available == 1000)
        #expect(volume.addingPurgeableBonus(10_000).used == 0)
        #expect(volume.addingPurgeableBonus(-10_000).available == 0)
        #expect(volume.addingPurgeableBonus(100).available == 500)
    }
}
