import AppKit
import Observation
import OSLog
import Sparkle

/// 更新流程的紀錄：log stream --predicate 'subsystem BEGINSWITH "com.chiehming.PopDisk" AND category == "update"'
private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopDisk", category: "update")

/// App 內更新（Sparkle）。feed 與公鑰寫在 Config/Info.plist
@Observable
@MainActor
final class UpdateStore: NSObject {
    /// 背景檢查找到、使用者還沒處理的新版本；選單會顯示「安裝…」
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // delegate 是 self，要等 super.init 之後才能建立
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        #if DEBUG
        // 測試更新用：-checkForUpdatesAtLaunch YES 直接跳出更新視窗（選單列面板無法用 UI 腳本點開）
        if UserDefaults.standard.bool(forKey: "checkForUpdatesAtLaunch") {
            Task {
                // startUpdater 是非同步完成的，太早呼叫 checkForUpdates 會被忽略
                try? await Task.sleep(for: .seconds(2))
                checkForUpdates()
            }
        }
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        // 選單列 App 沒有 Dock 圖示，不先啟用的話更新視窗會在其他 App 後面
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    nonisolated static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension UpdateStore: SPUUpdaterDelegate {
    /// 測試更新用：Debug 版可以用 -updateFeedURL http://127.0.0.1:8765/appcast.xml 改用本機 feed
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "updateFeedURL")
        #else
        return nil
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("found update \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        log.info("no update: \(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        log.error("update aborted: \(error.localizedDescription, privacy: .public)")
    }
}

// Sparkle 都在主執行緒呼叫 delegate，但 header 沒標 MainActor
extension UpdateStore: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        log.info("scheduled update \(update.displayVersionString, privacy: .public), immediateFocus=\(immediateFocus)")
        // 剛啟動或閒置一段時間後，交給 Sparkle 直接顯示；否則改用選單裡的提示與通知，不打斷使用者
        return immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        log.info("will show update, sparkleHandles=\(handleShowingUpdate), userInitiated=\(state.userInitiated)")
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
        NotificationService.shared.post(
            title: String(localized: "PopDisk \(update.displayVersionString) is available"),
            body: String(localized: "Open the PopDisk menu to install it."),
            identifier: "update-available"
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        log.info("update received user attention")
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        log.info("update session finished")
        availableVersion = nil
    }
}
