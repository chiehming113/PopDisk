import ServiceManagement

/// 登入時自動開啟 PopDisk（系統設定 → 一般 → 登入項目）
@MainActor
enum LoginItemService {
    enum Status {
        case enabled
        case disabled
        /// 使用者需要到系統設定允許
        case requiresApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
