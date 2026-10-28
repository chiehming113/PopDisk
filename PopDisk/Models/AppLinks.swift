import Foundation

/// 公開 repo 上給使用者看的頁面。開發用的 repo 是私有的，連結一律指向公開 repo（每次發佈時原始碼也會同步過去）
enum AppLinks {
    private static let repository = "https://github.com/chiehming113/PopDisk"

    static let website = URL(string: repository)!
    static let releaseNotes = URL(string: "\(repository)/blob/main/CHANGELOG.md")!
    static let reportProblem = URL(string: "\(repository)/issues/new/choose")!

    /// 繁中是參考譯文，正式條款是英文的 LICENSE
    static var license: URL {
        URL(string: "\(repository)/blob/main/\(prefersChinese ? "LICENSE.zh-Hant.md" : "LICENSE")")!
    }

    static var privacy: URL {
        URL(string: "\(repository)/blob/main/\(prefersChinese ? "PRIVACY.zh-Hant.md" : "PRIVACY.md")")!
    }

    /// 跟著 App 實際使用的介面語言，不是系統的第一語言
    static var prefersChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    }
}
