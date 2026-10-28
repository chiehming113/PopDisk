import AppKit
import UserNotifications

/// 系統通知。第一次要發通知時才請求權限。
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    /// 同時發出多則通知時，都要等同一次授權完成；否則授權未決定前送出的會被系統丟掉
    private var authorizationTask: Task<Void, Never>?

    func post(title: String, body: String, identifier: String = UUID().uuidString) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorizationTask == nil {
                center.delegate = self
                authorizationTask = Task {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                }
            }
            await authorizationTask?.value
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // 同一個 identifier 會取代舊的通知（例如同一顆碟的空間警示）
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// PopDisk 是選單列 App，常被視為「前景」；不實作的話通知不會顯示
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
