import Foundation

/// 一顆實體外接裝置（或磁碟映像檔），退出時以整顆為單位。
struct ExternalDrive: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case disk
        case diskImage
    }

    /// 實體整碟的 BSD 名稱，例如 disk4
    let id: String
    var name: String
    var kind: Kind
    var volumes: [Volume]
    var link: LinkInfo?
    var serialNumber: String?
    /// 分割表中最小的分割區 GUID；MBR 或沒有分割表的裝置為 nil
    var partitionUUID: String?

    /// 個人設定（暱稱、圖示等）的 key，換插孔或重開機都不變。
    /// 優先用分割區 GUID：卷宗是一個一個出現的，以卷宗 UUID 為準時 key 會在出現過程中變動
    var preferenceKey: String {
        "drive:" + (partitionUUID ?? volumes.compactMap(\.uuid).sorted().first ?? id)
    }

    /// 舊版以卷宗 UUID 當 key，遷移設定用
    var legacyPreferenceKeys: [String] {
        volumes.compactMap(\.uuid).sorted().map { "drive:" + $0 }
    }

    /// 第一個已掛載的卷宗位置（在 Finder 開啟等快速動作用）
    var primaryMountURL: URL? {
        volumes.first { $0.isMounted }?.mountURL
    }

    var symbolName: String {
        switch kind {
        case .disk: "externaldrive.fill"
        case .diskImage: "opticaldisc.fill"
        }
    }
}

/// 裝置上的一個卷宗（分割區或 APFS 卷宗）。
struct Volume: Identifiable, Hashable, Sendable {
    /// BSD 名稱，例如 disk4s1
    let id: String
    var name: String
    var mountURL: URL?
    var fileSystem: String?
    var uuid: String?
    var totalBytes: Int64?
    var availableBytes: Int64?

    var isMounted: Bool { mountURL != nil }

    var usedFraction: Double? {
        guard let totalBytes, let availableBytes, totalBytes > 0 else { return nil }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }

    /// 給使用者看的檔案系統名稱
    var fileSystemDisplayName: String? {
        switch fileSystem {
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "msdos": "FAT32"
        case "exfat": "exFAT"
        case "ntfs": "NTFS"
        case let other?: other.uppercased()
        case nil: nil
        }
    }
}

enum EjectState: Equatable, Sendable {
    case idle
    case ejecting
    /// 被佔用；清單可能是空的（佔用者是看不到的系統程式）
    case busy([BusyProcess])
    case failed(String)

    var canRetry: Bool {
        switch self {
        case .busy, .failed: true
        case .idle, .ejecting: false
        }
    }
}
