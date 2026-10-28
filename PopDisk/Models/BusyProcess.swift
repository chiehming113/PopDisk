import Foundation

/// 正在使用某個卷宗、導致無法退出的程式。
struct BusyProcess: Identifiable, Hashable, Sendable {
    let pid: pid_t
    /// 程式本身的名稱，例如 zsh、Preview
    let name: String
    /// 所屬的一般 App（例如 zsh 屬於 Terminal）；本身就是 App 時與 pid 相同
    var ownerApp: OwnerApp?

    struct OwnerApp: Hashable, Sendable {
        let pid: pid_t
        let name: String
        let bundlePath: String?
    }

    var id: pid_t { pid }

    /// 本身就是一般 App（可以請它正常結束，會跳出儲存對話框）
    var isApp: Bool { ownerApp?.pid == pid }
}
