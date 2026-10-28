#if DEBUG
import AppKit
import SwiftUI

/// 產生 README 用的截圖（只在 Debug 版）：在螢幕外的視窗畫出畫面再存成 PNG，
/// 不需要螢幕錄製權限，也不會拍到螢幕上的其他內容。
///
/// 用法：
///   PopDisk.app/Contents/MacOS/PopDisk -snapshotDirectory /path/to/dir [-snapshotVolumes 'A,B'] [-AppleLanguages '(zh-Hant)']
@MainActor
enum SnapshotRenderer {
    /// 只拍這些名稱的硬碟與網路碟（逗號分隔），避免把開發者自己的硬碟、NAS 拍進公開的截圖。
    /// Store 的 reload 會套用，只影響記憶體中的清單，不會寫回設定
    static let volumeNames: Set<String>? = UserDefaults.standard.string(forKey: "snapshotVolumes")
        .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }

    static func runIfRequested(
        settings: AppSettings,
        volumeStore: VolumeStore,
        networkStore: NetworkStore,
        throughputStore: ThroughputStore,
        preferencesStore: PreferencesStore,
        updateStore: UpdateStore
    ) {
        guard let directory = UserDefaults.standard.string(forKey: "snapshotDirectory") else { return }
        let suffix = UserDefaults.standard.string(forKey: "snapshotSuffix") ?? ""
        Task { @MainActor in
            // 等 DiskArbitration 回報硬碟、網路碟量測完連線速度
            try? await Task.sleep(for: .seconds(4))
            volumeStore.reload()
            networkStore.reload()
            try? await Task.sleep(for: .seconds(3))

            let menu = MenuContentView()
                .environment(volumeStore)
                .environment(networkStore)
                .environment(throughputStore)
                .environment(preferencesStore)
                .environment(updateStore)
                .background(Color(nsColor: .windowBackgroundColor))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                await render(menu, appearance: appearance, to: URL(filePath: directory).appending(path: "menu-\(name)\(suffix).png"))
            }

            let settingsView = SettingsView()
                .environment(settings)
                .environment(networkStore)
                .environment(preferencesStore)
                .environment(updateStore)
                .background(Color(nsColor: .windowBackgroundColor))
            // 高度要放得下「一般」分頁的全部內容（2026-10-27 加了「更新」區塊）
            await render(settingsView, appearance: .aqua, size: CGSize(width: 520, height: 600),
                   to: URL(filePath: directory).appending(path: "settings\(suffix).png"))

            // TabView 在螢幕外只畫得出第一個分頁，「關於」另外直接畫
            let aboutView = AboutSettingsView()
                .environment(updateStore)
                .background(Color(nsColor: .windowBackgroundColor))
            await render(aboutView, appearance: .aqua, size: CGSize(width: 520, height: 560),
                   to: URL(filePath: directory).appending(path: "about\(suffix).png"))
            NSApp.terminate(nil)
        }
    }

    private static func render<Content: View>(_ view: Content, appearance: NSAppearance.Name,
                                               size: CGSize? = nil, to url: URL) async {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size ?? hosting.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderBack(nil)
        // 選單的捲動區域高度是畫出來量過之後才更新的（onGeometryChange），等一輪再算大小
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let fitting = size ?? hosting.fittingSize
        window.setContentSize(fitting)
        hosting.frame = CGRect(origin: .zero, size: fitting)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("snapshot: \(url.path)")
    }
}
#endif
