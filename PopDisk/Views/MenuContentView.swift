import SwiftUI

struct MenuContentView: View {
    @Environment(VolumeStore.self) private var store
    @Environment(NetworkStore.self) private var networkStore
    @Environment(ThroughputStore.self) private var throughput
    @Environment(PreferencesStore.self) private var preferences
    @Environment(UpdateStore.self) private var updates
    @Environment(\.openSettings) private var openSettings

    /// 鍵盤選取中的列
    @State private var selection: RowID?
    /// 展開資訊面板的列
    @State private var expanded: Set<RowID> = []
    @FocusState private var isFocused: Bool
    /// 硬碟清單與底部（更新提示＋按鈕）的實際高度，用來讓捲動區域跟著內容長高、到上限才開始捲動
    @State private var listHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// 整個面板的寬度與高度上限（高度上限包含底部按鈕）
    private static let panelWidth: CGFloat = 300
    private static let maxPanelHeight: CGFloat = 600

    /// footerHeight 包含更新提示與分隔線
    private var maxListHeight: CGFloat { Self.maxPanelHeight - footerHeight }

    private enum RowID: Hashable {
        case drive(ExternalDrive.ID)
        case network(NetworkVolume.ID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        externalSection
                        Divider()
                        networkSection
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // ScrollView 本身沒有理想高度，要自己給：內容多高就多高，超過上限才捲動
                .frame(height: min(listHeight, maxListHeight))
                .scrollBounceBehavior(.basedOnSize)
                // 展開／收合資訊的動畫中，外框高度會比內容晚一拍，短暫「超出」就會跳出捲軸再慢慢淡出；
                // 內容其實沒超過上限時一律不顯示捲軸
                .scrollIndicators(listHeight > maxListHeight ? .automatic : .never)
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            VStack(spacing: 0) {
                if let version = updates.availableVersion {
                    Divider()
                    updateBanner(version: version)
                }
                Divider()
                footer
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: Self.panelWidth)
        .background { keyboardShortcuts }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.return) { openSelection(); return .handled }
        .onKeyPress(.escape) {
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        }
        .onAppear {
            store.reload()
            networkStore.reload()
            throughput.isMenuOpen = true
            isFocused = true
        }
        .onDisappear {
            throughput.isMenuOpen = false
            selection = nil
        }
        .animation(.default, value: store.drives)
        .animation(.default, value: store.ejectedNotices.map(\.id))
        .animation(.default, value: networkStore.volumes)
        .animation(.default, value: expanded)
    }

    // MARK: - 排序後、可見的項目

    private var visibleDrives: [ExternalDrive] {
        preferences.visible(store.drives, key: \.preferenceKey) { drive in
            drive.volumes.first?.name ?? drive.name
        }
    }

    private var visibleNetworkVolumes: [NetworkVolume] {
        preferences.visible(networkStore.volumes, key: \.preferenceKey, name: \.name)
    }

    private var hiddenCount: Int {
        store.drives.count + networkStore.volumes.count - visibleDrives.count - visibleNetworkVolumes.count
    }

    private var rowIDs: [RowID] {
        visibleDrives.map { .drive($0.id) } + visibleNetworkVolumes.map { .network($0.id) }
    }

    // MARK: - 外接硬碟

    private var externalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("External Drives")
                Spacer()
                if visibleDrives.count > 1 {
                    Button("Eject All", action: ejectAll)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Eject all external drives (⇧⌘E)")
                }
            }

            ForEach(store.ejectedNotices) { notice in
                Label("“\(notice.name)” can be safely removed.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            if visibleDrives.isEmpty {
                emptyText("No drives connected")
            } else {
                ForEach(visibleDrives) { drive in
                    driveRow(drive)
                        .id(RowID.drive(drive.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func driveRow(_ drive: ExternalDrive) -> some View {
        let id = RowID.drive(drive.id)
        let key = drive.preferenceKey
        let name = drive.volumes.first?.name ?? drive.name
        return DriveRowView(
            drive: drive,
            preference: preferences.preference(for: key),
            ejectState: store.ejectState(for: drive),
            rate: throughput.rate(for: drive),
            mountingVolumeIDs: store.mountingVolumeIDs,
            mountErrors: store.mountErrors,
            isSelected: selection == id,
            actions: actions(for: id, key: key, name: name, kind: .external, mountURL: drive.primaryMountURL),
            onEject: { Task { await store.eject(drive) } },
            onMount: { volume in Task { await store.mount(volume, on: drive) } },
            onTerminate: { process in Task { await store.terminate(process, thenEject: drive) } },
            onForceEject: {
                // 與列上顯示的名稱一致：有暱稱就用暱稱
                let title = preferences.preference(for: key)?.nickname ?? drive.volumes.map(\.name).joined(separator: ", ")
                if confirmForceEject(name: title) {
                    Task { await store.eject(drive, force: true) }
                }
            }
        )
    }

    // MARK: - 網路硬碟

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Network Drives")

            ForEach(visibleNetworkVolumes) { volume in
                networkRow(volume)
                    .id(RowID.network(volume.id))
            }

            ForEach(networkStore.disconnectedFavorites) { favorite in
                NetworkFavoriteRowView(
                    favorite: favorite,
                    isConnecting: networkStore.connectingFavoriteIDs.contains(favorite.id),
                    error: networkStore.connectErrors[favorite.id],
                    onConnect: { Task { await networkStore.connect(favorite) } }
                )
            }

            if visibleNetworkVolumes.isEmpty && networkStore.favorites.isEmpty {
                emptyText("No network drives connected")
                Button("Add a Network Drive…", action: showSettings)
                    .buttonStyle(.link)
                    .font(.callout)
            }

            if hiddenCount > 0 {
                Button("\(hiddenCount) hidden — show in Settings…", action: showSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func networkRow(_ volume: NetworkVolume) -> some View {
        let id = RowID.network(volume.id)
        let key = volume.preferenceKey
        var rowActions = actions(for: id, key: key, name: volume.name, kind: .network, mountURL: volume.mountURL)
        if networkStore.favorite(for: volume) == nil, volume.serverURL != nil {
            rowActions.addFavorite = { networkStore.addFavorite(from: volume) }
        }
        return NetworkVolumeRowView(
            volume: volume,
            preference: preferences.preference(for: key),
            ejectState: networkStore.ejectState(for: volume),
            link: networkStore.links[volume.id],
            rate: throughput.rate(for: volume),
            isSelected: selection == id,
            actions: rowActions,
            onEject: { Task { await networkStore.eject(volume) } },
            onTerminate: { process in Task { await networkStore.terminate(process, thenEject: volume) } },
            onForceEject: {
                if confirmForceEject(name: preferences.preference(for: key)?.nickname ?? volume.name) {
                    Task { await networkStore.eject(volume, force: true) }
                }
            }
        )
    }

    // MARK: - 動作

    private func actions(for id: RowID, key: String, name: String, kind: VolumePreference.Kind, mountURL: URL?) -> RowActions {
        let preference = preferences.preference(for: key)
        return RowActions(
            mountURL: mountURL,
            isPinned: preference?.isPinned == true,
            isExpanded: expanded.contains(id),
            toggleInfo: { toggleInfo(id) },
            rename: {
                preferences.record(key: key, name: name, kind: kind)
                if case .some(let nickname) = QuickActions.askForNickname(current: preference?.nickname, originalName: name) {
                    preferences.setNickname(nickname, for: key)
                }
            },
            togglePin: {
                preferences.record(key: key, name: name, kind: kind)
                preferences.update(key) { $0.isPinned.toggle() }
            },
            hide: {
                preferences.record(key: key, name: name, kind: kind)
                preferences.update(key) { $0.isHidden = true }
            }
        )
    }

    private func toggleInfo(_ id: RowID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func ejectAll() {
        let ids = Set(visibleDrives.map(\.id))
        Task { await store.ejectAll(only: ids) }
    }

    // MARK: - 鍵盤操作

    private func moveSelection(by offset: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            self.selection = offset > 0 ? ids.first : ids.last
            return
        }
        self.selection = ids[(index + offset + ids.count) % ids.count]
    }

    private func openSelection() {
        switch selection {
        case .drive(let id):
            if let url = store.drives.first(where: { $0.id == id })?.primaryMountURL {
                QuickActions.openInFinder(url)
            }
        case .network(let id):
            if let volume = networkStore.volumes.first(where: { $0.id == id }) {
                QuickActions.openInFinder(volume.mountURL)
            }
        case nil:
            break
        }
    }

    private func ejectSelection() {
        switch selection {
        case .drive(let id):
            if let drive = store.drives.first(where: { $0.id == id }) {
                Task { await store.eject(drive) }
            }
        case .network(let id):
            if let volume = networkStore.volumes.first(where: { $0.id == id }) {
                Task { await networkStore.eject(volume) }
            }
        case nil:
            break
        }
    }

    /// ⌘ 組合鍵：放在背景的隱形按鈕上，選單面板取得焦點時就能觸發
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Eject Selected", action: ejectSelection)
                .keyboardShortcut("e")
            Button("Eject All", action: ejectAll)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Show Info") {
                if let selection { toggleInfo(selection) }
            }
            .keyboardShortcut("i")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - 共用

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func emptyText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
    }

    /// 選單列面板裡的 SwiftUI alert 不穩定，用 NSAlert 確認
    private func confirmForceEject(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Force eject “\(name)”?")
        alert.informativeText = String(localized: "Apps using the disk may lose unsaved changes, and files being copied may be damaged.")
        let forceButton = alert.addButton(withTitle: String(localized: "Force Eject"))
        forceButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showSettings() {
        // 選單列 App 沒有 Dock 圖示，需先啟用 App，設定視窗才會跳到最前面
        NSApp.activate()
        openSettings()
    }

    private func updateBanner(version: String) -> some View {
        HStack {
            Label("PopDisk \(version) is available", systemImage: "arrow.down.circle.fill")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Install…", action: updates.checkForUpdates)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: showSettings)
                .keyboardShortcut(",")
            Spacer()
            Text("↑↓ select · ↩ open · ⌘E eject")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit PopDisk") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }
}
