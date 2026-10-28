import Foundation
import Observation
import SwiftUI  // Array.move(fromOffsets:toOffset:)

/// 使用者對某顆硬碟的個人設定
struct VolumePreference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case external
        case network
    }

    var kind: Kind
    /// 最後一次看到時的名稱（硬碟沒接上時，在設定裡顯示用）
    var lastSeenName: String
    var nickname: String?
    var symbolName: String?
    var isPinned = false
    var isHidden = false

    /// 使用者是否改過任何設定（只有 lastSeenName 的是自動建立的紀錄）
    var isCustomized: Bool {
        nickname != nil || symbolName != nil || isPinned || isHidden
    }
}

/// 暱稱、圖示、排序、釘選、隱藏。以 `preferenceKey`（卷宗 UUID / 分享位址）記住，硬碟拔掉再接回來也還在。
@Observable
@MainActor
final class PreferencesStore {
    private(set) var preferences: [String: VolumePreference] = [:]
    /// 使用者自訂的順序（設定裡拖曳）；不在清單內的排在後面、依名稱排序
    private(set) var order: [String] = []

    /// 可選的圖示
    static let symbolChoices = [
        "externaldrive.fill", "internaldrive.fill", "externaldrive.fill.badge.timemachine",
        "opticaldisc.fill", "sdcard.fill", "memorychip.fill", "server.rack", "archivebox.fill",
        "photo.fill", "film.fill", "music.note", "doc.fill", "briefcase.fill", "house.fill",
        "gamecontroller.fill", "camera.fill",
    ]

    private enum Keys {
        static let preferences = "volumePreferences"
        static let order = "volumeOrder"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.preferences),
           let decoded = try? JSONDecoder().decode([String: VolumePreference].self, from: data) {
            preferences = decoded
        }
        order = defaults.stringArray(forKey: Keys.order) ?? []
    }

    func preference(for key: String) -> VolumePreference? {
        preferences[key]
    }

    /// 記錄看到的硬碟，讓它出現在設定的清單裡
    func record(key: String, name: String, kind: VolumePreference.Kind) {
        if var existing = preferences[key] {
            guard existing.lastSeenName != name else { return }
            existing.lastSeenName = name
            preferences[key] = existing
        } else {
            preferences[key] = VolumePreference(kind: kind, lastSeenName: name)
        }
        save()
    }

    func update(_ key: String, _ change: (inout VolumePreference) -> Void) {
        guard var preference = preferences[key] else { return }
        change(&preference)
        // 輸入中不 trim（否則打不出字與字之間的空白），只把全空白的當成沒有暱稱；送出時由 setNickname 再 trim
        if preference.nickname?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            preference.nickname = nil
        }
        preferences[key] = preference
        save()
    }

    func setNickname(_ nickname: String?, for key: String) {
        update(key) { $0.nickname = nickname?.trimmingCharacters(in: .whitespaces) }
    }

    /// 外接碟的 key 從「最小卷宗 UUID」改為「最小分割區 UUID」後，把舊 key 的設定搬過來。
    /// record 會先建立空白紀錄，所以「新 key 沒有設定」以使用者是否改過任何東西判斷，而不是有沒有紀錄。
    func migrate(to key: String, from legacyKeys: [String]) {
        let legacyKeys = legacyKeys.filter { $0 != key && preferences[$0] != nil }
        guard !legacyKeys.isEmpty else { return }
        // 每次硬碟清單變動都會呼叫；新舊 key 都有設定時舊的搬不過去，沒改變就不要重寫 UserDefaults
        var changed = false
        if preferences[key]?.isCustomized != true,
           let source = legacyKeys.first(where: { preferences[$0]?.isCustomized == true }),
           let moved = preferences[source] {
            preferences[key] = moved
            if order.contains(source) {
                order.removeAll { $0 == key }
                if let index = order.firstIndex(of: source) { order[index] = key }
            }
            preferences[source] = nil
            changed = true
        }
        // 舊程式卷宗一個一個出現時留下的空白紀錄，一併清掉
        for legacy in legacyKeys where preferences[legacy]?.isCustomized == false {
            preferences[legacy] = nil
            order.removeAll { $0 == legacy }
            changed = true
        }
        if changed { save() }
    }

    func forget(_ key: String) {
        preferences[key] = nil
        order.removeAll { $0 == key }
        save()
    }

    /// 設定清單用的排序：釘選在前，再依自訂順序、名稱
    var sortedKeys: [String] {
        preferences.keys.sorted { a, b in
            areInIncreasingOrder((a, preferences[a]?.lastSeenName ?? a), (b, preferences[b]?.lastSeenName ?? b))
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var keys = sortedKeys
        keys.move(fromOffsets: source, toOffset: destination)
        order = keys
        save()
    }

    /// 選單用：過濾隱藏的，並依釘選、自訂順序、名稱排序。
    /// 不同硬碟可能有相同的 key（複製的映像檔、同一分享用不同帳號掛載），所以不能以 key 去重
    func visible<Item: Identifiable>(_ items: [Item], key: (Item) -> String, name: (Item) -> String) -> [Item]
    where Item.ID: Comparable {
        items
            .filter { preferences[key($0)]?.isHidden != true }
            .sorted { a, b in
                let lhs = (key(a), name(a)), rhs = (key(b), name(b))
                if areInIncreasingOrder(lhs, rhs) { return true }
                if areInIncreasingOrder(rhs, lhs) { return false }
                // sorted 不保證穩定，同 key 同名稱時用 ID 固定順序，避免每次重繪對調
                return a.id < b.id
            }
    }

    private func areInIncreasingOrder(_ a: (key: String, name: String), _ b: (key: String, name: String)) -> Bool {
        let pinnedA = preferences[a.key]?.isPinned == true
        let pinnedB = preferences[b.key]?.isPinned == true
        if pinnedA != pinnedB { return pinnedA }
        let indexA = order.firstIndex(of: a.key) ?? .max
        let indexB = order.firstIndex(of: b.key) ?? .max
        if indexA != indexB { return indexA < indexB }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Keys.preferences)
        }
        defaults.set(order, forKey: Keys.order)
    }
}
