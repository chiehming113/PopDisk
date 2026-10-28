import Foundation
import Observation

/// 定時取樣外接碟與網卡的傳輸量。
/// 只在選單打開、或選單列需要顯示活動／速度時取樣，其餘時間不耗電。
@Observable
@MainActor
final class ThroughputStore {
    /// key 為實體整碟的 BSD 名稱
    private(set) var driveRates: [ExternalDrive.ID: TransferRate] = [:]
    /// key 為網卡名稱
    private(set) var interfaceRates: [String: TransferRate] = [:]

    var isMenuOpen = false {
        didSet { reschedule() }
    }

    /// 選單列只計算外接碟：網卡流量包含瀏覽器等其他程式，會讓指示一直亮
    var externalTotal: TransferRate {
        driveRates.values.reduce(.zero, +)
    }

    var isTransferring: Bool { externalTotal.isActive }

    private let volumeStore: VolumeStore
    private let networkStore: NetworkStore
    private let settings: AppSettings

    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var lastDriveCounters: [String: ThroughputService.Counters] = [:]
    @ObservationIgnored private var lastInterfaceCounters: [String: ThroughputService.Counters] = [:]
    @ObservationIgnored private var lastSampleTime: ContinuousClock.Instant?

    init(volumeStore: VolumeStore, networkStore: NetworkStore, settings: AppSettings) {
        self.volumeStore = volumeStore
        self.networkStore = networkStore
        self.settings = settings
        reschedule()
    }

    func rate(for drive: ExternalDrive) -> TransferRate? {
        driveRates[drive.id]
    }

    func rate(for volume: NetworkVolume) -> TransferRate? {
        networkStore.links[volume.id]?.interfaceName.flatMap { interfaceRates[$0] }
    }

    private var shouldSample: Bool {
        isMenuOpen || settings.showActivity || settings.showSpeed
    }

    /// 設定或選單開關改變時呼叫：只在「需不需要取樣」改變時啟動或停止。
    /// 已在取樣時不重啟，迴圈每輪都會讀取最新的間隔
    func reschedule() {
        guard shouldSample != (samplingTask != nil) else { return }
        guard shouldSample else {
            samplingTask?.cancel()
            samplingTask = nil
            driveRates = [:]
            interfaceRates = [:]
            lastSampleTime = nil
            return
        }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                sample()
                // 選單關著時只為選單列指示取樣，放慢一點
                let interval = isMenuOpen ? settings.updateInterval : max(settings.updateInterval, 2)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func sample() {
        let now = ContinuousClock.now
        let elapsed = lastSampleTime.map { duration in
            let components = (now - duration).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
        lastSampleTime = now

        var driveCounters: [String: ThroughputService.Counters] = [:]
        for drive in volumeStore.drives {
            driveCounters[drive.id] = ThroughputService.diskCounters(bsdName: drive.id)
        }
        let neededInterfaces = Set(networkStore.links.values.compactMap(\.interfaceName))
        let interfaceCounters = neededInterfaces.isEmpty
            ? [:]
            : ThroughputService.interfaceCounters().filter { neededInterfaces.contains($0.key) }

        if let elapsed {
            driveRates = Self.rates(from: lastDriveCounters, to: driveCounters, over: elapsed)
            interfaceRates = Self.rates(from: lastInterfaceCounters, to: interfaceCounters, over: elapsed)
        }
        lastDriveCounters = driveCounters
        lastInterfaceCounters = interfaceCounters
    }

    /// 只有前後兩次都有取樣到的項目才算得出速度
    private static func rates(
        from previous: [String: ThroughputService.Counters],
        to current: [String: ThroughputService.Counters],
        over seconds: Double
    ) -> [String: TransferRate] {
        current.reduce(into: [:]) { result, entry in
            guard let old = previous[entry.key] else { return }
            result[entry.key] = ThroughputService.rate(from: old, to: entry.value, over: seconds)
        }
    }
}
