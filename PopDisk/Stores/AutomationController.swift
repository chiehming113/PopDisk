import AppKit
import Foundation

/// 串接各種「自動發生」的事：通知、空間不足警示、睡眠前退出、全域快捷鍵
@MainActor
final class AutomationController {
    private let settings: AppSettings
    private let volumeStore: VolumeStore
    private let networkStore: NetworkStore
    private let throughput: ThroughputStore
    private let preferences: PreferencesStore
    private let notifications = NotificationService.shared
    private let sleepService = SystemSleepService()
    private let hotKeys = HotKeyService()

    /// 已發過空間警示的卷宗（回到門檻以上才會再警示）
    private var lowSpaceWarned: Set<String> = []
    /// 睡眠前沒退出成功的硬碟名稱，喚醒後通知
    private var failedSleepEjects: [String] = []
    private var spaceCheckTask: Task<Void, Never>?
    /// 啟動時 DiskArbitration 會逐一回報既有的硬碟，這段時間內出現的不算「新接上」
    private let startedAt = ContinuousClock.now

    init(settings: AppSettings, volumeStore: VolumeStore, networkStore: NetworkStore,
         throughput: ThroughputStore, preferences: PreferencesStore) {
        self.settings = settings
        self.volumeStore = volumeStore
        self.networkStore = networkStore
        self.throughput = throughput
        self.preferences = preferences
    }

    func start() {
        volumeStore.onDrivesChanged = { [weak self] old, new in self?.drivesChanged(from: old, to: new) }
        volumeStore.onEjectFinished = { [weak self] drive, failure in self?.ejectFinished(drive, failure: failure) }

        sleepService.onWillSleep = { [weak self] done in
            guard let self, settings.ejectBeforeSleep else { return done() }
            Task {
                await self.ejectBeforeSleep()
                done()
            }
        }
        sleepService.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFailedSleepEjects() }
        }

        hotKeys.onPress = { [weak self] action in self?.hotKeyPressed(action) }
        hotKeys.start()
        settings.hotKeyConflicts = Set(registerHotKeys())
        settings.onHotKeysChange = { [weak self] in
            // 錄製中不重新註冊：按另一個欄位的「清除」也會觸發這裡，註冊回來就又會攔截錄製的按鍵
            guard let self, settings.recordingHotKey == nil else { return }
            settings.hotKeyConflicts = Set(registerHotKeys())
        }
        // Carbon 全域快捷鍵比錄製用的 NSEvent monitor 先收到按鍵，錄製期間要先全部取消，
        // 否則按到已設定的組合會直接執行那個動作，也無法偵測重複
        settings.onRecordingHotKeyChange = { [weak self] in
            guard let self else { return }
            if settings.recordingHotKey != nil {
                hotKeys.unregisterAll()
            } else {
                settings.hotKeyConflicts = Set(registerHotKeys())
            }
        }

        // 拷貝檔案時空間會持續變少，定時檢查（只讀 statfs，很便宜）
        spaceCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.checkFreeSpace(refresh: true)
            }
        }
    }

    /// 回傳註冊失敗（可能與其他 App 衝突）的動作
    private func registerHotKeys() -> [HotKeyService.Action] {
        var failed: [HotKeyService.Action] = []
        if !hotKeys.set(settings.ejectAllHotKey, for: .ejectAll) { failed.append(.ejectAll) }
        if !hotKeys.set(settings.toggleMenuHotKey, for: .toggleMenu) { failed.append(.toggleMenu) }
        return failed
    }

    // MARK: - 硬碟接上／退出

    private func drivesChanged(from old: [ExternalDrive], to new: [ExternalDrive]) {
        if ContinuousClock.now - startedAt > .seconds(5), settings.notifyOnConnect {
            let oldIDs = Set(old.map(\.id))
            for drive in new where !oldIDs.contains(drive.id) && drive.kind == .disk {
                notifications.post(
                    title: String(localized: "Drive connected"),
                    body: drive.volumes.map(\.name).joined(separator: ", "),
                    identifier: "connected-\(drive.id)"
                )
            }
        }
        // drives() 剛讀過容量，不必在主執行緒再讀一次（睡眠中的硬碟會讓選單卡住）
        checkFreeSpace(refresh: false)
    }

    private func ejectFinished(_ drive: ExternalDrive, failure: EjectState?) {
        // 選單開著時畫面上已經有提示，不重複通知
        guard settings.notifyOnEject, !throughput.isMenuOpen else { return }
        let name = drive.volumes.map(\.name).joined(separator: ", ")
        switch failure {
        case nil:
            notifications.post(
                title: String(localized: "“\(name)” can be safely removed."),
                body: String(localized: "You can now unplug the drive."),
                identifier: "eject-\(drive.id)"
            )
        case .busy(let processes):
            let apps = processes.map { $0.ownerApp?.name ?? $0.name }
            notifications.post(
                title: String(localized: "Couldn't eject “\(name)”"),
                body: apps.isEmpty
                    ? String(localized: "The disk is in use. Close any apps using it and try again.")
                    : String(localized: "In use by \(apps.formatted(.list(type: .and))).")
                ,
                identifier: "eject-\(drive.id)"
            )
        case .failed(let message):
            notifications.post(title: String(localized: "Couldn't eject “\(name)”"), body: message, identifier: "eject-\(drive.id)")
        case .idle, .ejecting:
            break
        }
    }

    // MARK: - 空間不足

    /// - Parameter refresh: 重新讀取容量。拷貝檔案時空間會持續變少，定時檢查才需要
    private func checkFreeSpace(refresh: Bool) {
        guard settings.notifyLowSpace else {
            lowSpaceWarned.removeAll()
            return
        }
        let threshold = Double(settings.lowSpaceThreshold) / 100
        var candidates: [(id: String, name: String, total: Int64?, available: Int64?)] = []
        for drive in volumeStore.drives where drive.kind == .disk {
            for volume in drive.volumes where volume.isMounted {
                var total = volume.totalBytes, available = volume.availableBytes
                if refresh, let url = volume.mountURL,
                   let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                    total = values.volumeTotalCapacity.map(Int64.init)
                    available = values.volumeAvailableCapacity.map(Int64.init)
                }
                candidates.append((volume.id, volume.name, total, available))
            }
        }
        // 網路碟用 getfsstat 快取值，不會因為伺服器失聯卡住
        for volume in networkStore.volumes {
            candidates.append((volume.id, volume.name, volume.totalBytes, volume.availableBytes))
        }

        var stillLow: Set<String> = []
        for candidate in candidates {
            guard let total = candidate.total, let available = candidate.available, total > 0 else { continue }
            let freeFraction = Double(available) / Double(total)
            guard freeFraction < threshold else { continue }
            stillLow.insert(candidate.id)
            guard !lowSpaceWarned.contains(candidate.id) else { continue }
            notifications.post(
                title: String(localized: "“\(candidate.name)” is almost full"),
                body: String(localized: "Only \(available.compactByteCount) left (\(Int((freeFraction * 100).rounded()))%)."),
                identifier: "space-\(candidate.id)"
            )
        }
        lowSpaceWarned = stillLow
    }

    // MARK: - 睡眠

    private func ejectBeforeSleep() async {
        failedSleepEjects = []
        // 磁碟映像檔睡眠不會損壞，不退出。
        // 隱藏的硬碟也要退出：隱藏只影響選單顯示，睡眠時拔線造成的損壞與它無關
        for drive in volumeStore.drives where drive.kind == .disk {
            await volumeStore.eject(drive)
            if volumeStore.ejectState(for: drive).canRetry {
                failedSleepEjects.append(drive.volumes.map(\.name).joined(separator: ", "))
            }
        }
    }

    private func reportFailedSleepEjects() {
        guard !failedSleepEjects.isEmpty else { return }
        notifications.post(
            title: String(localized: "Some drives weren't ejected before sleep"),
            body: failedSleepEjects.formatted(.list(type: .and)),
            identifier: "sleep-eject"
        )
        failedSleepEjects = []
    }

    // MARK: - 全域快捷鍵

    private func hotKeyPressed(_ action: HotKeyService.Action) {
        guard settings.recordingHotKey == nil else { return }
        switch action {
        case .ejectAll:
            // 與選單的「全部退出」一致：使用者隱藏的硬碟（例如 Time Machine）不動
            let ids = Set(preferences.visible(volumeStore.drives, key: \.preferenceKey, name: \.name).map(\.id))
            Task { await volumeStore.ejectAll(only: ids) }
        case .toggleMenu:
            toggleMenu()
        }
    }

    /// MenuBarExtra 沒有公開 API 可以打開面板。
    /// macOS 27 起選單列項目由系統代管，點擊不再經過按鈕的 target／action（`performClick` 沒有作用），
    /// 而是由系統開啟一個 expanded interface session，SwiftUI 收到後才顯示面板；
    /// 開啟只有私有的 `_requestExpandedInterfaceSession`，關閉可用公開的 `session.cancel()`
    private func toggleMenu() {
        guard let window = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }) else { return }
        let statusItemKey = Selector(("statusItem"))
        let requestSession = Selector(("_requestExpandedInterfaceSession"))
        if #available(macOS 27, *), window.responds(to: statusItemKey),
           let item = window.perform(statusItemKey)?.takeUnretainedValue() as? NSStatusItem,
           item.responds(to: requestSession) {
            if let session = item.expandedInterfaceSession {
                session.cancel()
            } else {
                NSApp.activate()
                item.perform(requestSession)
            }
            return
        }
        if let button = Self.findStatusBarButton(in: window.contentView) {
            NSApp.activate()
            button.performClick(nil)
        }
    }

    private static func findStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findStatusBarButton(in: subview) { return button }
        }
        return nil
    }
}
