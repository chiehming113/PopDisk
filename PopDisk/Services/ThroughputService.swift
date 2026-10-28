import Foundation
import IOKit

/// 每秒傳輸量（bytes/s）
struct TransferRate: Hashable, Sendable {
    /// 外接碟：讀取；網路：下載
    var inbound: Double = 0
    /// 外接碟：寫入；網路：上傳
    var outbound: Double = 0

    static let zero = TransferRate()

    /// 低於這個值視為閒置，避免背景零星 I/O 讓指示一直閃
    static let activityThreshold: Double = 64 * 1024

    var isActive: Bool { inbound >= Self.activityThreshold || outbound >= Self.activityThreshold }

    /// 低於 1 KB/s 在列上顯示「—」，避免一直出現「0 KB/s」或零星的幾 bytes
    static let displayThreshold: Double = 1024

    static func + (lhs: TransferRate, rhs: TransferRate) -> TransferRate {
        TransferRate(inbound: lhs.inbound + rhs.inbound, outbound: lhs.outbound + rhs.outbound)
    }

    /// 例如「12.3 MB/s」
    static func format(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond.rounded()).formatted(.byteCount(style: .file)) + "/s"
    }
}

/// 讀取累計傳輸量；速度由兩次取樣相減而來
enum ThroughputService {
    struct Counters: Sendable {
        var inbound: UInt64
        var outbound: UInt64
    }

    /// 實體整碟的累計讀寫量：IOMedia 的上一層 IOBlockStorageDriver 的 Statistics
    static func diskCounters(bsdName: String) -> Counters? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        var driver: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(media, kIOServicePlane, &driver) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(driver) }
        guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else { return nil }
        return Counters(inbound: read, outbound: written)
    }

    /// 網卡的累計收送量
    static func interfaceCounters() -> [String: Counters] {
        InterfaceStatistics.current().mapValues { Counters(inbound: $0.receivedBytes, outbound: $0.sentBytes) }
    }

    static func rate(from old: Counters, to new: Counters, over seconds: Double) -> TransferRate {
        guard seconds > 0 else { return .zero }
        // 計數器重置（例如裝置重新接上）時不要算出負值
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) / seconds : 0 }
        return TransferRate(inbound: delta(old.inbound, new.inbound), outbound: delta(old.outbound, new.outbound))
    }
}
