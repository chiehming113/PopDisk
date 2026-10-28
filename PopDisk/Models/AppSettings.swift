import Foundation
import Observation

/// 使用者設定，存在 UserDefaults
@Observable
@MainActor
final class AppSettings {
    /// 任何會影響取樣排程的設定改變時通知
    @ObservationIgnored var onChange: (() -> Void)?
    /// 全域快捷鍵改變時通知（重新註冊）
    @ObservationIgnored var onHotKeysChange: (() -> Void)?
    /// 開始或結束錄製快捷鍵時通知（錄製期間要暫停全域快捷鍵）
    @ObservationIgnored var onRecordingHotKeyChange: (() -> Void)?

    var showDriveCount: Bool {
        didSet { save(showDriveCount, Keys.showDriveCount) }
    }
    var showActivity: Bool {
        didSet { save(showActivity, Keys.showActivity) }
    }
    var showSpeed: Bool {
        didSet { save(showSpeed, Keys.showSpeed) }
    }
    /// 傳輸速度取樣間隔（秒）
    var updateInterval: Double {
        didSet { save(updateInterval, Keys.updateInterval) }
    }

    var notifyOnConnect: Bool {
        didSet { save(notifyOnConnect, Keys.notifyOnConnect) }
    }
    var notifyOnEject: Bool {
        didSet { save(notifyOnEject, Keys.notifyOnEject) }
    }
    var notifyLowSpace: Bool {
        didSet { save(notifyLowSpace, Keys.notifyLowSpace) }
    }
    /// 剩餘空間低於這個百分比時警示
    var lowSpaceThreshold: Int {
        didSet { save(lowSpaceThreshold, Keys.lowSpaceThreshold) }
    }
    var ejectBeforeSleep: Bool {
        didSet { save(ejectBeforeSleep, Keys.ejectBeforeSleep) }
    }
    var ejectAllHotKey: HotKey? {
        didSet { saveHotKey(ejectAllHotKey, Keys.ejectAllHotKey) }
    }
    var toggleMenuHotKey: HotKey? {
        didSet { saveHotKey(toggleMenuHotKey, Keys.toggleMenuHotKey) }
    }

    /// 註冊失敗（通常是與其他 App 的快捷鍵衝突）的動作，不儲存
    var hotKeyConflicts: Set<HotKeyService.Action> = []

    /// 正在錄製快捷鍵的動作，不儲存。同時只能有一個欄位在錄製
    var recordingHotKey: HotKeyService.Action? {
        didSet {
            guard recordingHotKey != oldValue else { return }
            onRecordingHotKeyChange?()
        }
    }

    static let updateIntervals: [Double] = [1, 2, 5]
    static let lowSpaceThresholds = [5, 10, 15, 20]

    private enum Keys {
        static let showDriveCount = "menuBarShowsDriveCount"
        static let showActivity = "menuBarShowsActivity"
        static let showSpeed = "menuBarShowsSpeed"
        static let updateInterval = "updateInterval"
        static let notifyOnConnect = "notifyOnConnect"
        static let notifyOnEject = "notifyOnEject"
        static let notifyLowSpace = "notifyLowSpace"
        static let lowSpaceThreshold = "lowSpaceThreshold"
        static let ejectBeforeSleep = "ejectBeforeSleep"
        static let ejectAllHotKey = "ejectAllHotKey"
        static let toggleMenuHotKey = "toggleMenuHotKey"
    }

    init(defaults: UserDefaults = .standard) {
        showDriveCount = defaults.object(forKey: Keys.showDriveCount) as? Bool ?? true
        showActivity = defaults.object(forKey: Keys.showActivity) as? Bool ?? true
        showSpeed = defaults.object(forKey: Keys.showSpeed) as? Bool ?? false
        let interval = defaults.double(forKey: Keys.updateInterval)
        updateInterval = Self.updateIntervals.contains(interval) ? interval : 2
        notifyOnConnect = defaults.object(forKey: Keys.notifyOnConnect) as? Bool ?? false
        notifyOnEject = defaults.object(forKey: Keys.notifyOnEject) as? Bool ?? true
        notifyLowSpace = defaults.object(forKey: Keys.notifyLowSpace) as? Bool ?? true
        let threshold = defaults.integer(forKey: Keys.lowSpaceThreshold)
        lowSpaceThreshold = Self.lowSpaceThresholds.contains(threshold) ? threshold : 10
        ejectBeforeSleep = defaults.object(forKey: Keys.ejectBeforeSleep) as? Bool ?? false
        ejectAllHotKey = Self.loadHotKey(defaults, Keys.ejectAllHotKey)
        toggleMenuHotKey = Self.loadHotKey(defaults, Keys.toggleMenuHotKey)
    }

    private func saveHotKey(_ hotKey: HotKey?, _ key: String) {
        UserDefaults.standard.set(hotKey.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        onHotKeysChange?()
    }

    private static func loadHotKey(_ defaults: UserDefaults, _ key: String) -> HotKey? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }
}
