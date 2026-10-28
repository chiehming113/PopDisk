import Foundation

/// 硬碟與 Mac 之間的連線方式與協商速度
struct LinkInfo: Hashable, Sendable {
    enum Interconnect: Hashable, Sendable {
        case usb
        case thunderbolt
        case pcie
        /// 插在 Mac 內建讀卡機的 SD 卡
        case sdCard
        case wifi
        case ethernet
        case loopback
        case other(String)
    }

    /// 連線速度受限的原因（可以由使用者改善的情況才提示）
    enum Limitation: Hashable, Sendable {
        /// USB 3 以上的裝置只連到 USB 2 速度，通常是接口、Hub 或線材的問題
        case usbBelowCapability
        /// 走 Wi‑Fi，但同時有可用的有線網路
        case wifiWhileWiredAvailable
        /// 乙太網路只協商到 100 Mb/s 以下
        case slowEthernet
    }

    var interconnect: Interconnect
    /// 協商速度（bit/s）
    var bitsPerSecond: Int64?
    /// 補充說明，例如 PCIe 3.0 ×4
    var detail: String?
    /// 網路延遲（TCP 連線建立時間）
    var latency: Duration?
    var limitation: Limitation?
    /// 網路碟走的網卡，例如 en0（取樣網路傳輸量用）
    var interfaceName: String?
    /// SD 卡：讀卡機接到 Mac 的 PCIe 通道，例如 PCIe 2.0 ×1（只放在資訊面板，選單上顯示卡本身的速度）
    var readerDetail: String?

    var symbolName: String {
        switch interconnect {
        case .usb: "cable.connector"
        case .thunderbolt: "bolt.horizontal"
        case .pcie: "memorychip"
        case .sdCard: "sdcard"
        case .wifi: "wifi"
        case .ethernet: "network"
        case .loopback: "arrow.triangle.2.circlepath"
        case .other: "link"
        }
    }

    /// 例如「USB 10 Gb/s」、「Thunderbolt · PCIe 3.0 ×4」、「Wi‑Fi 1.2 Gb/s · 3 ms」
    var summary: String {
        var parts: [String] = []
        // PCIe 的 detail 本身就以「PCIe」開頭，不再重複
        var head = interconnect == .pcie && detail != nil ? "" : interconnectName
        if let bitsPerSecond, detail == nil {
            head += " " + Self.format(bitsPerSecond: bitsPerSecond)
        }
        if !head.isEmpty { parts.append(head) }
        if let detail { parts.append(detail) }
        if let latency {
            let milliseconds = Double(latency.components.seconds) * 1000 + Double(latency.components.attoseconds) / 1e15
            parts.append(milliseconds < 1 ? "<1 ms" : "\(Int(milliseconds.rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }

    var interconnectName: String {
        switch interconnect {
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt"
        case .pcie: "PCIe"
        case .sdCard: "SD"
        case .wifi: "Wi‑Fi"
        case .ethernet: String(localized: "Ethernet")
        case .loopback: String(localized: "This Mac")
        case .other(let name): name
        }
    }

    var limitationMessage: String? {
        switch limitation {
        case .usbBelowCapability:
            String(localized: "This drive supports USB 3 but is connected at USB 2 speed. Try a different port, hub, or cable.")
        case .wifiWhileWiredAvailable:
            String(localized: "Using Wi‑Fi even though a wired network is available.")
        case .slowEthernet:
            String(localized: "Ethernet is connected at only 100 Mb/s or less. Check the cable or switch.")
        case nil:
            nil
        }
    }

    static func format(bitsPerSecond: Int64) -> String {
        let value = Double(bitsPerSecond)
        func trimmed(_ number: Double) -> String {
            number.formatted(.number.precision(.fractionLength(0...1)))
        }
        if value >= 1e9 { return "\(trimmed(value / 1e9)) Gb/s" }
        if value >= 1e6 { return "\(trimmed(value / 1e6)) Mb/s" }
        return "\(trimmed(value / 1e3)) kb/s"
    }
}
