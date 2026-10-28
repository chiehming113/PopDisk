import Foundation

enum NetworkProtocol: String, Codable, Hashable, Sendable {
    case smb
    case nfs
    case webdav
    case afp

    /// statfs 的 f_fstypename
    init?(fileSystemType: String) {
        switch fileSystemType {
        case "smbfs": self = .smb
        case "nfs": self = .nfs
        case "webdav": self = .webdav
        case "afpfs": self = .afp
        default: return nil
        }
    }

    init?(scheme: String?) {
        switch scheme?.lowercased() {
        case "smb", "cifs": self = .smb
        case "nfs": self = .nfs
        case "http", "https": self = .webdav
        case "afp": self = .afp
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .smb: "SMB"
        case .nfs: "NFS"
        case .webdav: "WebDAV"
        case .afp: "AFP"
        }
    }
}

/// 已掛載的網路卷宗
struct NetworkVolume: Identifiable, Hashable, Sendable {
    let name: String
    let mountURL: URL
    let networkProtocol: NetworkProtocol
    /// 可用來重新掛載的伺服器位址（不含密碼），例如 smb://user@nas.local/Photos
    let serverURL: URL?
    var totalBytes: Int64?
    var availableBytes: Int64?

    var id: String { mountURL.path }

    /// 個人設定的 key：同一個分享（不分使用者名稱、大小寫）共用
    var preferenceKey: String {
        serverURL.flatMap(ShareKey.init).map { "share:\($0.networkProtocol.rawValue)://\($0.host)/\($0.path)" }
            ?? "share:" + mountURL.path
    }

    var usedFraction: Double? {
        guard let totalBytes, let availableBytes, totalBytes > 0 else { return nil }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }

    /// 選單顯示用的伺服器名稱：Bonjour 服務名稱（MyNAS._smb._tcp.local）一般人看不懂，只留 MyNAS
    var displayHost: String? {
        guard let host = serverURL?.host(percentEncoded: false) else { return nil }
        return BonjourService(host: host)?.name ?? host
    }
}

/// Finder 透過 Bonjour 連線時，位址是服務名稱，例如 MyNAS._smb._tcp.local
struct BonjourService: Hashable, Sendable {
    let name: String
    /// 例如 _smb._tcp
    let type: String
    let domain: String

    init?(host: String) {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let index = labels.firstIndex(where: { $0 == "_tcp" || $0 == "_udp" }),
              index >= 2, labels[index - 1].hasPrefix("_") else { return nil }
        name = labels[..<(index - 1)].joined(separator: ".")
        type = labels[index - 1] + "." + labels[index]
        domain = labels[(index + 1)...].joined(separator: ".")
    }
}

/// 使用者儲存的常用網路硬碟；密碼存在 Keychain，不在這裡
struct NetworkFavorite: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// 不含使用者名稱與密碼的位址，例如 smb://nas.local/Photos
    var url: URL
    var username: String?
    var mountAtLaunch = false

    var networkProtocol: NetworkProtocol? { NetworkProtocol(scheme: url.scheme) }

    /// 連線用的位址（帶入使用者名稱）
    var connectURL: URL {
        guard let username, !username.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.user = username
        return components.url ?? url
    }
}

/// 比對「同一個分享」用的 key：協定、主機、路徑，忽略使用者名稱與大小寫
struct ShareKey: Hashable, Sendable {
    let networkProtocol: NetworkProtocol
    let host: String
    let path: String

    init?(_ url: URL) {
        guard let networkProtocol = NetworkProtocol(scheme: url.scheme),
              let host = url.host(percentEncoded: false) else { return nil }
        self.networkProtocol = networkProtocol
        self.host = host.lowercased()
        self.path = url.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
