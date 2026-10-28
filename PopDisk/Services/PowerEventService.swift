import AppKit

/// 系統睡眠／喚醒事件
@MainActor
final class PowerEventService {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onWillSleep?() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDidWake?() }
            },
        ]
    }
}
