import Darwin
import Foundation

/// How much memory this process holds, and how much of its malloc heap is
/// actually in use (#337).
///
/// Four numbers, because one alone hides the failure this exists to catch. A
/// build of the pricing work sat at a 1.29 GB footprint two hours after launch;
/// its malloc heap held 566 MB of dirty pages of which only 244 MB were live
/// allocations. The rest was memory freed after the upgrade's big passes and
/// never handed back, because a page with one surviving allocation on it stays
/// dirty however much of it is free. `footprint` alone would have read as "the
/// app needs 1.3 GB"; `mallocDirty - mallocLive` says most of it is waste.
public struct ProcessMemory: Sendable, Equatable {
    /// `phys_footprint`: what Activity Monitor's Memory column shows and what
    /// the system's memory pressure charges this process for.
    public var footprint: UInt64
    /// The highest `footprint` has been since launch.
    public var peakFootprint: UInt64
    /// Bytes malloc has handed out and not had back, across every zone.
    public var mallocLive: UInt64
    /// Resident dirty plus compressed pages in malloc's VM regions: what the
    /// heap costs the machine, live or not. Pages malloc has already marked
    /// reusable are not counted, matching `footprint`.
    public var mallocDirty: UInt64

    public init(footprint: UInt64, peakFootprint: UInt64, mallocLive: UInt64, mallocDirty: UInt64) {
        self.footprint = footprint
        self.peakFootprint = peakFootprint
        self.mallocLive = mallocLive
        self.mallocDirty = mallocDirty
    }

    /// Dirty heap pages that hold no live allocation.
    public var mallocFragmentation: UInt64 {
        mallocDirty > mallocLive ? mallocDirty - mallocLive : 0
    }

    /// `footprint 412 MB peak 2190 MB malloc live 244 MB dirty 566 MB`, the
    /// shape the `[Memory]` log line carries so a regression is greppable.
    public var summary: String {
        "footprint \(Self.mb(footprint)) MB peak \(Self.mb(peakFootprint)) MB "
            + "malloc live \(Self.mb(mallocLive)) MB dirty \(Self.mb(mallocDirty)) MB"
    }

    static func mb(_ bytes: UInt64) -> Int { Int((Double(bytes) / 1_000_000).rounded()) }

    /// Read it now. A walk of this process's VM regions (a few thousand, a few
    /// milliseconds), so it is for logging and measurement, not a hot path.
    public static func current() -> ProcessMemory {
        let vm = taskVMInfo()
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return ProcessMemory(footprint: vm.footprint, peakFootprint: vm.peak,
                             mallocLive: UInt64(stats.size_in_use),
                             mallocDirty: mallocRegionDirtyBytes())
    }

    private static func taskVMInfo() -> (footprint: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    /// The VM tags malloc's zones put on their regions (`mach/vm_statistics.h`).
    /// SQLite's page cache, Core Data's row cache and DuckDB all allocate
    /// through malloc, so they are in here too.
    private static let mallocTags: Set<UInt32> = [
        UInt32(VM_MEMORY_MALLOC), UInt32(VM_MEMORY_MALLOC_SMALL), UInt32(VM_MEMORY_MALLOC_LARGE),
        UInt32(VM_MEMORY_MALLOC_HUGE), UInt32(VM_MEMORY_MALLOC_TINY),
        UInt32(VM_MEMORY_MALLOC_LARGE_REUSABLE), UInt32(VM_MEMORY_MALLOC_LARGE_REUSED),
        UInt32(VM_MEMORY_MALLOC_NANO), UInt32(VM_MEMORY_MALLOC_MEDIUM),
    ]

    private static func mallocRegionDirtyBytes() -> UInt64 {
        let page = UInt64(getpagesize())
        var address: mach_vm_address_t = 0
        var total: UInt64 = 0
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_extended_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            var object: mach_port_t = 0
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO,
                                   $0, &count, &object)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if mallocTags.contains(info.user_tag) {
                total += UInt64(info.pages_dirtied) * page + UInt64(info.pages_swapped_out) * page
            }
            address += size
        }
        return total
    }
}
