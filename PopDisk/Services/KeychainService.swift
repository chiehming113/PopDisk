import Foundation
import Security

/// 網路硬碟密碼存在登入鑰匙圈（internet password）。
/// 加上固定的 label 前綴，只讀寫 PopDisk 自己建立的項目，不會去讀 Finder 存的密碼（那會跳出授權詢問）。
enum KeychainService {
    private static let labelPrefix = "PopDisk: "

    static func password(for url: URL, account: String) -> String? {
        var query = baseQuery(for: url, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for url: URL, account: String) -> Bool {
        var query = baseQuery(for: url, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func setPassword(_ password: String, for url: URL, account: String) -> Bool {
        let data = Data(password.utf8)
        let query = baseQuery(for: url, account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func deletePassword(for url: URL, account: String) {
        SecItemDelete(baseQuery(for: url, account: account) as CFDictionary)
    }

    private static func baseQuery(for url: URL, account: String) -> [String: Any] {
        let host = url.host(percentEncoded: false) ?? ""
        return [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
            kSecAttrPath as String: url.path(percentEncoded: false),
            kSecAttrLabel as String: labelPrefix + host,
        ]
    }
}
