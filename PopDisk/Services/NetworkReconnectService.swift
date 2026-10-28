import Foundation
import Network

/// 判斷哪些網路卷宗是「意外斷線」，並在網路恢復或喚醒後重新連線。
///
/// 規則：卷宗消失時，如果正在睡眠、剛喚醒不久、或網路斷線中，視為意外斷線、列入待重連；
/// 其他情況（使用者從 PopDisk 或 Finder 退出）不重連。
@MainActor
final class NetworkReconnectService {
    var isEnabled = true
    /// 嘗試重新掛載一個伺服器位址
    var reconnect: ((URL) async -> Void)?
    /// 網路從不可用變成可用（包含 App 啟動後第一次）
    var onNetworkAvailable: (() -> Void)?

    private(set) var isNetworkAvailable = false
    /// 目前有可用的有線網路（用來提示「有線可用卻走 Wi‑Fi」）
    private(set) var isWiredAvailable = false
    /// 網路狀態有任何變化（例如切換 Wi‑Fi / 有線）
    var onPathChange: (() -> Void)?
    private var mountedURLs: Set<URL> = []
    private var pendingURLs: Set<URL> = []
    /// PopDisk 自己退出的，不算意外斷線
    private var intentionallyEjected: Set<URL> = []
    private var isSleeping = false
    private var lastWake: Date?

    private let pathMonitor = NWPathMonitor()
    private let power = PowerEventService()

    /// 喚醒後這段時間內消失的卷宗也算意外斷線（系統常在喚醒後才回報卸載）
    private static let wakeGracePeriod: TimeInterval = 60

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wired = path.availableInterfaces.contains { $0.type == .wiredEthernet }
            MainActor.assumeIsolated {
                self?.isWiredAvailable = wired
                self?.networkChanged(available: available)
                self?.onPathChange?()
            }
        }
        pathMonitor.start(queue: .main)

        power.onWillSleep = { [weak self] in self?.isSleeping = true }
        power.onDidWake = { [weak self] in
            guard let self else { return }
            isSleeping = false
            lastWake = .now
            // 喚醒後網路通常要幾秒才會真的可用
            scheduleReconnect(after: .seconds(5))
        }
        power.start()
    }

    /// 網路卷宗清單變動時呼叫
    func volumesChanged(serverURLs: Set<URL>) {
        let disappeared = mountedURLs.subtracting(serverURLs)
        for url in disappeared where intentionallyEjected.remove(url) == nil && isDisruption {
            pendingURLs.insert(url)
        }
        mountedURLs = serverURLs
        pendingURLs.subtract(serverURLs)
    }

    func willEject(serverURL: URL) {
        intentionallyEjected.insert(serverURL)
        pendingURLs.remove(serverURL)
    }

    func ejectFailed(serverURL: URL) {
        intentionallyEjected.remove(serverURL)
    }

    private var isDisruption: Bool {
        if isSleeping || !isNetworkAvailable { return true }
        guard let lastWake else { return false }
        return Date.now.timeIntervalSince(lastWake) < Self.wakeGracePeriod
    }

    private func networkChanged(available: Bool) {
        let becameAvailable = available && !isNetworkAvailable
        isNetworkAvailable = available
        guard becameAvailable else { return }
        onNetworkAvailable?()
        scheduleReconnect(after: .seconds(2))
    }

    private func scheduleReconnect(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            await reconnectPending()
            // 伺服器可能比網路晚就緒，再試一次
            try? await Task.sleep(for: .seconds(15))
            await reconnectPending()
        }
    }

    private func reconnectPending() async {
        guard isEnabled, isNetworkAvailable, !isSleeping else { return }
        for url in pendingURLs.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            await reconnect?(url)
        }
    }
}
