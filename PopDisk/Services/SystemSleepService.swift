import Foundation
import IOKit
import IOKit.pwr_mgt

/// 在系統睡眠前執行工作，並讓系統等待完成。
/// `NSWorkspace.willSleepNotification` 只是通知、不會等待；IOKit 的電源通知可以延後睡眠，
/// 直到呼叫 `IOAllowPowerChange`（系統最多等約 30 秒）。
@MainActor
final class SystemSleepService {
    /// 即將睡眠；完成後必須呼叫 completion
    var onWillSleep: ((@escaping @MainActor () -> Void) -> Void)?

    // IOMessage.h 的 kIOMessage* 是 iokit_common_msg() 巨集，Swift 看不到
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, messageType, argument in
            guard let context else { return }
            let service = Unmanaged<SystemSleepService>.fromOpaque(context).takeUnretainedValue()
            // argument 是要回傳給 IOAllowPowerChange 的識別碼，轉成整數才能跨 closure 傳遞
            let notificationID = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                service.handle(messageType: messageType, notificationID: notificationID)
            }
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
    }

    private func handle(messageType: natural_t, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            // 閒置睡眠前的詢問：不阻止
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            guard let onWillSleep else {
                IOAllowPowerChange(rootPort, notificationID)
                return
            }
            let port = rootPort
            onWillSleep {
                IOAllowPowerChange(port, notificationID)
            }
        default:
            break
        }
    }
}
