import Foundation
import Observation
import SwiftUI  // Array.move(fromOffsets:toOffset:)

@Observable
@MainActor
final class NetworkStore {
    private(set) var volumes: [NetworkVolume] = []
    private(set) var favorites: [NetworkFavorite] = []
    private(set) var ejectStates: [NetworkVolume.ID: EjectState] = [:]
    private(set) var connectingFavoriteIDs: Set<NetworkFavorite.ID> = []
    private(set) var connectErrors: [NetworkFavorite.ID: String] = [:]
    private(set) var links: [NetworkVolume.ID: LinkInfo] = [:]

    var reconnectAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(reconnectAutomatically, forKey: Keys.reconnect)
            reconnectService.isEnabled = reconnectAutomatically
        }
    }

    private enum Keys {
        static let favorites = "networkFavorites"
        static let reconnect = "reconnectNetworkDrives"
    }

    private let diskService: DiskArbitrationService
    private let mountService = NetworkMountService()
    private let reconnectService = NetworkReconnectService()
    private var didMountAtLaunch = false
    private var linkRefreshTask: Task<Void, Never>?
    /// 量測進行中又有變動（新掛載、網路切換），結束後要再量一輪
    private var needsLinkRefresh = false
    private var needsFullLinkRefresh = false
    /// 已量測過的網路碟（含連不到的）。每次量測都要開 TCP 連線，同一條路徑下不需要重量
    private var probedIDs: Set<NetworkVolume.ID> = []

    init(diskService: DiskArbitrationService) {
        self.diskService = diskService
        reconnectAutomatically = UserDefaults.standard.object(forKey: Keys.reconnect) as? Bool ?? true
        favorites = Self.loadFavorites()

        mountService.onChange = { [weak self] in self?.reload() }
        mountService.start()

        reconnectService.isEnabled = reconnectAutomatically
        reconnectService.reconnect = { [weak self] url in await self?.reconnect(to: url) }
        reconnectService.onNetworkAvailable = { [weak self] in self?.mountFavoritesAtLaunch() }
        reconnectService.onPathChange = { [weak self] in self?.refreshLinks(all: true) }
        reconnectService.start()

        reload()
    }

    // MARK: - 查詢

    func ejectState(for volume: NetworkVolume) -> EjectState {
        ejectStates[volume.id] ?? .idle
    }

    func favorite(for volume: NetworkVolume) -> NetworkFavorite? {
        guard let key = volume.serverURL.flatMap(ShareKey.init) else { return nil }
        return favorites.first { ShareKey($0.url) == key }
    }

    /// 還沒連上的常用網路硬碟
    var disconnectedFavorites: [NetworkFavorite] {
        let mountedKeys = Set(volumes.compactMap { $0.serverURL.flatMap(ShareKey.init) })
        return favorites.filter { favorite in
            ShareKey(favorite.url).map { !mountedKeys.contains($0) } ?? true
        }
    }

    func hasSavedPassword(for favorite: NetworkFavorite) -> Bool {
        guard let username = favorite.username, !username.isEmpty else { return false }
        return KeychainService.hasPassword(for: favorite.url, account: username)
    }

    func reload() {
        volumes = mountService.mountedVolumes()
        #if DEBUG
        if let names = SnapshotRenderer.volumeNames {
            volumes = volumes.filter { names.contains($0.name) }
            favorites = favorites.filter { names.contains($0.name) }
        }
        #endif
        let ids = Set(volumes.map(\.id))
        ejectStates = ejectStates.filter { ids.contains($0.key) }
        reconnectService.volumesChanged(serverURLs: Set(volumes.compactMap(\.serverURL)))
        links = links.filter { ids.contains($0.key) }
        probedIDs = probedIDs.intersection(ids)
        refreshLinks()
    }

    /// 量測網路碟走的網卡、速率與延遲（各需一次 TCP 連線，進行中就等這輪結束再量一次）。
    /// - Parameter all: 網路路徑改變時全部重量；否則只量還沒量過的（新掛上的）
    func refreshLinks(all: Bool = false) {
        guard linkRefreshTask == nil else {
            needsLinkRefresh = true
            needsFullLinkRefresh = needsFullLinkRefresh || all
            return
        }
        if all { probedIDs.removeAll() }
        let targets = volumes
            .filter { !probedIDs.contains($0.id) }
            .compactMap { volume in volume.serverURL.map { (volume, $0) } }
        guard !targets.isEmpty else { return }
        probedIDs.formUnion(targets.map(\.0.id))
        linkRefreshTask = Task {
            for (volume, serverURL) in targets {
                let link = await LinkSpeedService.networkLink(
                    to: serverURL,
                    protocol: volume.networkProtocol,
                    wiredAvailable: reconnectService.isWiredAvailable
                )
                // 量測期間可能已經退出，不要把它寫回去（否則會繼續取樣它的網卡）
                if volumes.contains(where: { $0.id == volume.id }) {
                    links[volume.id] = link
                }
            }
            linkRefreshTask = nil
            if needsLinkRefresh {
                let all = needsFullLinkRefresh
                needsLinkRefresh = false
                needsFullLinkRefresh = false
                refreshLinks(all: all)
            }
        }
    }

    // MARK: - 連線

    func connect(_ favorite: NetworkFavorite) async {
        connectingFavoriteIDs.insert(favorite.id)
        connectErrors[favorite.id] = nil
        defer { connectingFavoriteIDs.remove(favorite.id) }
        do {
            try await mount(favorite, allowUI: true)
        } catch .cancelled {
            // 使用者在系統登入視窗按了取消，不顯示錯誤
        } catch {
            connectErrors[favorite.id] = error.localizedDescription
        }
    }

    private func mount(_ favorite: NetworkFavorite, allowUI: Bool) async throws(NetworkMountError) {
        let password = favorite.username.flatMap { username in
            username.isEmpty ? nil : KeychainService.password(for: favorite.url, account: username)
        }
        // 有存密碼就不跳視窗；沒有密碼時讓系統詢問
        try await mountService.mount(
            url: favorite.url,
            username: favorite.username,
            password: password,
            allowUI: allowUI && password == nil
        )
    }

    private func mountFavoritesAtLaunch() {
        guard !didMountAtLaunch else { return }
        didMountAtLaunch = true
        for favorite in disconnectedFavorites where favorite.mountAtLaunch {
            Task { await connect(favorite) }
        }
    }

    /// 意外斷線後的自動重連：不跳任何視窗，失敗就算了，等下一次機會
    private func reconnect(to serverURL: URL) async {
        let key = ShareKey(serverURL)
        if let favorite = favorites.first(where: { ShareKey($0.url) == key }) {
            try? await mount(favorite, allowUI: false)
        } else {
            try? await mountService.mount(url: serverURL, username: serverURL.user(percentEncoded: false), password: nil, allowUI: false)
        }
    }

    // MARK: - 退出

    func eject(_ volume: NetworkVolume, force: Bool = false) async {
        guard ejectState(for: volume) != .ejecting else { return }
        ejectStates[volume.id] = .ejecting
        if let serverURL = volume.serverURL { reconnectService.willEject(serverURL: serverURL) }
        do {
            try await diskService.unmountVolume(at: volume.mountURL, force: force)
            ejectStates[volume.id] = nil
        } catch {
            if let serverURL = volume.serverURL { reconnectService.ejectFailed(serverURL: serverURL) }
            switch error {
            case .busy:
                ejectStates[volume.id] = .busy(await BusyProcessService.processes(using: [volume.mountURL.path]))
            case .failed:
                ejectStates[volume.id] = .failed(error.localizedDescription)
            }
        }
    }

    func terminate(_ process: BusyProcess, thenEject volume: NetworkVolume) async {
        ejectStates[volume.id] = .ejecting
        _ = await BusyProcessService.terminate(process)
        ejectStates[volume.id] = nil
        await eject(volume)
    }

    // MARK: - 常用清單

    /// 把已連線的網路硬碟加入常用清單
    func addFavorite(from volume: NetworkVolume) {
        guard let serverURL = volume.serverURL, favorite(for: volume) == nil,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return }
        let username = components.user
        components.user = nil
        components.password = nil
        guard let url = components.url else { return }
        save(NetworkFavorite(name: volume.name, url: url, username: username), password: nil)
    }

    /// 新增或更新；password 為 nil 時保留原本 Keychain 內的密碼
    func save(_ favorite: NetworkFavorite, password: String?) {
        if let index = favorites.firstIndex(where: { $0.id == favorite.id }) {
            let old = favorites[index]
            // 位址或帳號改了，舊的密碼就對不上，一併移除
            if let oldUser = old.username, !oldUser.isEmpty,
               old.url != favorite.url || old.username != favorite.username {
                // 鑰匙圈 key 不含協定與埠號，新舊位址可能是同一個項目：先刪再寫，才不會把剛寫入的刪掉
                let oldPassword = KeychainService.password(for: old.url, account: oldUser)
                KeychainService.deletePassword(for: old.url, account: oldUser)
                if password == nil, let oldPassword, let newUser = favorite.username, !newUser.isEmpty {
                    KeychainService.setPassword(oldPassword, for: favorite.url, account: newUser)
                }
            }
            favorites[index] = favorite
        } else {
            favorites.append(favorite)
        }
        if let password, !password.isEmpty, let username = favorite.username, !username.isEmpty {
            KeychainService.setPassword(password, for: favorite.url, account: username)
        }
        connectErrors[favorite.id] = nil
        persistFavorites()
    }

    func delete(_ favorite: NetworkFavorite) {
        if let username = favorite.username, !username.isEmpty {
            KeychainService.deletePassword(for: favorite.url, account: username)
        }
        favorites.removeAll { $0.id == favorite.id }
        connectErrors[favorite.id] = nil
        persistFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        persistFavorites()
    }

    private func persistFavorites() {
        #if DEBUG
        // 截圖模式的清單被篩選過，存回去會弄丟使用者的常用清單
        if SnapshotRenderer.volumeNames != nil { return }
        #endif
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Keys.favorites)
        }
    }

    private static func loadFavorites() -> [NetworkFavorite] {
        guard let data = UserDefaults.standard.data(forKey: Keys.favorites) else { return [] }
        return (try? JSONDecoder().decode([NetworkFavorite].self, from: data)) ?? []
    }
}
