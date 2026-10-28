import CoreWLAN
import Darwin
import Foundation
import IOKit
import Network

/// 讀取外接碟的介面協商速度（IOKit），以及網路碟走的網卡速率與延遲。
enum LinkSpeedService {
    // MARK: - 外接碟

    /// 從實體整碟的 IOMedia 沿 IORegistry 往上找連接介面
    static func externalLink(media: io_registry_entry_t) -> LinkInfo? {
        var ancestors: [io_registry_entry_t] = []
        var entry = media
        IOObjectRetain(entry)
        var parent: io_registry_entry_t = 0
        while IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            ancestors.append(parent)
            entry = parent
        }
        defer {
            IOObjectRelease(media)
            ancestors.forEach { IOObjectRelease($0) }
        }

        let isThunderbolt = ancestors.contains { className(of: $0).localizedCaseInsensitiveContains("Thunderbolt") }

        // 內建讀卡機往上第一個介面是讀卡機晶片的 PCIe 通道，比 SD 卡能跑的速度快很多；真正的瓶頸是卡的匯流排模式
        if let slot = ancestors.first(where: { IOObjectConformsTo($0, "AppleSDXCSlot") != 0 }) {
            var link = sdCardLink(slot: slot)
            if let reader = ancestors.first(where: { IOObjectConformsTo($0, "IOPCIDevice") != 0 }) {
                link.readerDetail = pcieLink(device: reader, isThunderbolt: false, allowCapabilities: true)?.detail
            }
            return link
        }

        for ancestor in ancestors {
            if IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0 {
                return usbLink(device: ancestor)
            }
            if IOObjectConformsTo(ancestor, "IOPCIDevice") != 0,
               let link = pcieLink(device: ancestor, isThunderbolt: isThunderbolt) {
                return link
            }
        }

        // 找不到 USB / PCIe 裝置時，用磁碟驅動回報的介面名稱
        for ancestor in ancestors {
            if let characteristics = property(of: ancestor, "Protocol Characteristics") as? [String: Any],
               let interconnect = characteristics["Physical Interconnect"] as? String {
                switch interconnect {
                case "Virtual Interface": return nil  // 磁碟映像檔
                case "USB": return LinkInfo(interconnect: .usb)
                case "Thunderbolt": return LinkInfo(interconnect: .thunderbolt)
                case "PCI-Express": return LinkInfo(interconnect: isThunderbolt ? .thunderbolt : .pcie)
                default: return LinkInfo(interconnect: .other(interconnect))
                }
            }
        }
        return nil
    }

    /// 沿 IORegistry 往上找裝置序號（USB 裝置或 NVMe 控制器）
    static func serialNumber(media: io_registry_entry_t) -> String? {
        var entry = media
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        var parent: io_registry_entry_t = 0
        while IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(entry)
            entry = parent
            for key in ["USB Serial Number", "kUSBSerialNumberString", "Serial Number"] {
                if let serial = (property(of: entry, key) as? String)?.trimmingCharacters(in: .whitespaces),
                   !serial.isEmpty {
                    return serial
                }
            }
        }
        return nil
    }

    static func usbLink(device: io_registry_entry_t) -> LinkInfo {
        // 值的定義見 IOUSBHostFamilyDefinitions.h 的 tIOUSBHostConnectionSpeed
        let speedCode = (property(of: device, "USBSpeed") as? NSNumber)?.intValue
        var bitsPerSecond: Int64? = switch speedCode {
        case 1: 12_000_000
        case 2: 1_500_000
        case 3: 480_000_000
        case 4: 5_000_000_000
        case 5: 10_000_000_000
        case 6: 20_000_000_000
        default: nil
        }
        if let linkSpeed = (property(of: device, "UsbLinkSpeed") as? NSNumber)?.int64Value, linkSpeed > 0 {
            bitsPerSecond = linkSpeed
        }

        var link = LinkInfo(interconnect: .usb, bitsPerSecond: bitsPerSecond)
        // bcdUSB 0x0300 以上代表裝置支援 USB 3；實際只跑到 High Speed 以下就是被接口或線材拖慢
        if let bcdUSB = (property(of: device, "bcdUSB") as? NSNumber)?.intValue,
           bcdUSB >= 0x0300, let speedCode, speedCode <= 3 {
            link.limitation = .usbBelowCapability
        }
        return link
    }

    /// AppleSDXCSlot 的「Speed Mode」是卡目前協商的匯流排模式（實測 "UHS: SDR104"）。
    /// 數值是 SD 規格的匯流排上限（MB/s），卡本身的讀寫可能更慢
    static func sdCardLink(slot: io_registry_entry_t) -> LinkInfo {
        guard let mode = property(of: slot, "Speed Mode") as? String else { return LinkInfo(interconnect: .sdCard) }
        let upper = mode.uppercased()
        let known: [(token: String, name: String, megabytes: Double)] = [
            ("HD312", "UHS-II", 312), ("FD312", "UHS-II", 312), ("FD156", "UHS-II", 156),
            ("SDR104", "UHS-I", 104), ("DDR50", "UHS-I", 50), ("SDR50", "UHS-I", 50),
            ("SDR25", "UHS-I", 25), ("SDR12", "UHS-I", 12.5),
            ("HIGH SPEED", "High Speed", 25), ("DEFAULT", "Default Speed", 12.5),
        ]
        guard let match = known.first(where: { upper.contains($0.token) }) else {
            // 沒見過的模式（例如 UHS-II 的其他寫法）照系統字串顯示
            return LinkInfo(interconnect: .sdCard, detail: mode)
        }
        let speed = match.megabytes.formatted(.number.precision(.fractionLength(0...1)))
        return LinkInfo(
            interconnect: .sdCard,
            bitsPerSecond: Int64(match.megabytes * 8_000_000),
            detail: "\(match.name) \(speed) MB/s"
        )
    }

    /// IOPCIExpressLinkStatus / Capabilities 是 PCIe Link Status / Capabilities 暫存器：
    /// bit 0–3 為速度代號（1 = 2.5 GT/s … 5 = 32 GT/s），bit 4–9 為通道數。
    /// 讀卡機晶片沒插卡時會斷電，Status 讀到 0xFFFF；`allowCapabilities` 時改用 Capabilities（晶片支援的最高速度）
    static func pcieLink(device: io_registry_entry_t, isThunderbolt: Bool, allowCapabilities: Bool = false) -> LinkInfo? {
        var status = (property(of: device, "IOPCIExpressLinkStatus") as? NSNumber)?.intValue
        if status == nil || status == 0xFFFF {
            status = allowCapabilities ? (property(of: device, "IOPCIExpressLinkCapabilities") as? NSNumber)?.intValue : nil
        }
        guard let status else { return nil }
        let generation = status & 0xF
        let width = (status >> 4) & 0x3F
        let perLaneBits: Double? = switch generation {
        case 1: 2e9
        case 2: 4e9
        case 3: 7.877e9
        case 4: 15.754e9
        case 5: 31.508e9
        default: nil
        }
        guard let perLaneBits, width > 0 else { return nil }
        return LinkInfo(
            interconnect: isThunderbolt ? .thunderbolt : .pcie,
            bitsPerSecond: Int64(perLaneBits * Double(width)),
            detail: "PCIe \(generation).0 ×\(width)"
        )
    }

    private static func property(of entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func className(of entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &name)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - 網路碟

    /// 對伺服器建立 TCP 連線，取得走的網卡與連線建立時間，再讀該網卡的速率
    @MainActor
    static func networkLink(to serverURL: URL, protocol networkProtocol: NetworkProtocol, wiredAvailable: Bool) async -> LinkInfo? {
        guard let host = serverURL.host(percentEncoded: false),
              let port = NWEndpoint.Port(rawValue: UInt16(serverURL.port ?? defaultPort(for: networkProtocol, scheme: serverURL.scheme))) else {
            return nil
        }
        // 用名稱連線的時間包含 DNS / mDNS 解析（Bonjour 服務名稱每次都要重新解析，會多出幾十 ms），
        // 所以第一次只用來取得網卡與解析後的位址，延遲改量直接連位址的時間（取兩次中較短的）
        let first = await probe(endpoint(host: host, port: port))
        guard let interface = first.interface else { return nil }
        var latency: Duration?
        // 第一次就連不上時不再重試（每次最多等 3 秒）
        if first.latency != nil {
            let target = first.remoteEndpoint ?? endpoint(host: host, port: port)
            let second = await probe(target)
            let third = await probe(target)
            latency = [second.latency, third.latency].compactMap { $0 }.min() ?? first.latency
        }

        var link: LinkInfo
        switch interface.type {
        case .wifi:
            let rate = CWWiFiClient.shared().interface(withName: interface.name)?.transmitRate() ?? 0
            link = LinkInfo(interconnect: .wifi, bitsPerSecond: rate > 0 ? Int64(rate * 1_000_000) : nil)
            if wiredAvailable { link.limitation = .wifiWhileWiredAvailable }
        case .wiredEthernet:
            let rate = InterfaceStatistics.current()[interface.name]?.baudRate
            link = LinkInfo(interconnect: .ethernet, bitsPerSecond: rate.flatMap { $0 > 0 ? Int64($0) : nil })
            if let rate, rate > 0, rate <= 100_000_000 { link.limitation = .slowEthernet }
        case .loopback:
            link = LinkInfo(interconnect: .loopback)
        default:
            link = LinkInfo(interconnect: .other(interface.name))
        }
        link.latency = latency
        link.interfaceName = interface.name
        return link
    }

    private static func defaultPort(for networkProtocol: NetworkProtocol, scheme: String?) -> Int {
        switch networkProtocol {
        case .smb: 445
        case .nfs: 2049
        case .afp: 548
        case .webdav: scheme?.lowercased() == "https" ? 443 : 80
        }
    }

    private struct ProbeResult: Sendable {
        var interface: NWInterface?
        var latency: Duration?
        /// 解析後實際連上的位址（IP:port）
        var remoteEndpoint: NWEndpoint?
    }

    /// 確保 continuation 只 resume 一次（ready、失敗、逾時可能同時發生）
    @MainActor
    private final class ProbeOnce {
        private var continuation: CheckedContinuation<ProbeResult, Never>?
        init(_ continuation: CheckedContinuation<ProbeResult, Never>) { self.continuation = continuation }

        func finish(_ result: ProbeResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    /// Finder 透過 Bonjour 連線時，位址是服務名稱（例如 MyNAS._smb._tcp.local），DNS 解析不到，要改用 Bonjour 解析
    nonisolated static func endpoint(host: String, port: NWEndpoint.Port) -> NWEndpoint {
        if let service = BonjourService(host: host) {
            return .service(name: service.name, type: service.type, domain: service.domain, interface: nil)
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    @MainActor
    private static func probe(_ endpoint: NWEndpoint) async -> ProbeResult {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let start = ContinuousClock.now
        let result: ProbeResult = await withCheckedContinuation { continuation in
            let once = ProbeOnce(continuation)
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        once.finish(ProbeResult(interface: connection.currentPath?.availableInterfaces.first,
                                                latency: ContinuousClock.now - start,
                                                remoteEndpoint: connection.currentPath?.remoteEndpoint))
                    case .failed, .waiting:
                        // 連不上時仍可知道會走哪張網卡
                        once.finish(ProbeResult(interface: connection.currentPath?.availableInterfaces.first))
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                once.finish(ProbeResult(interface: connection.currentPath?.availableInterfaces.first))
            }
        }
        connection.cancel()
        return result
    }
}

/// 各網卡的速率與累計流量（64 位元，`NET_RT_IFLIST2`）
struct InterfaceStatistics: Sendable {
    let baudRate: UInt64
    let receivedBytes: UInt64
    let sentBytes: UInt64

    /// key 為網卡名稱，例如 en0
    static func current() -> [String: InterfaceStatistics] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceStatistics] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let key = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        result[key] = InterfaceStatistics(
                            baudRate: message.ifm_data.ifi_baudrate,
                            receivedBytes: message.ifm_data.ifi_ibytes,
                            sentBytes: message.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}
