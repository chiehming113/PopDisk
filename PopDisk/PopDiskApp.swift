import SwiftUI

@main
struct PopDiskApp: App {
    // App 啟動時就建立，開始監聽磁碟事件（不必等選單打開）
    @State private var settings: AppSettings
    @State private var volumeStore: VolumeStore
    @State private var networkStore: NetworkStore
    @State private var throughputStore: ThroughputStore
    @State private var preferencesStore: PreferencesStore
    @State private var updateStore: UpdateStore
    private let automation: AutomationController

    init() {
        let settings = AppSettings()
        let diskService = DiskArbitrationService()
        let volumeStore = VolumeStore(diskService: diskService)
        let networkStore = NetworkStore(diskService: diskService)
        let preferencesStore = PreferencesStore()
        let updateStore = UpdateStore()
        let throughputStore = ThroughputStore(volumeStore: volumeStore, networkStore: networkStore, settings: settings)
        settings.onChange = { [weak throughputStore] in throughputStore?.reschedule() }

        let automation = AutomationController(
            settings: settings, volumeStore: volumeStore, networkStore: networkStore,
            throughput: throughputStore, preferences: preferencesStore
        )
        automation.start()
        self.automation = automation

        #if DEBUG
        SnapshotRenderer.runIfRequested(
            settings: settings, volumeStore: volumeStore, networkStore: networkStore,
            throughputStore: throughputStore, preferencesStore: preferencesStore, updateStore: updateStore
        )
        #endif

        _settings = State(initialValue: settings)
        _volumeStore = State(initialValue: volumeStore)
        _networkStore = State(initialValue: networkStore)
        _throughputStore = State(initialValue: throughputStore)
        _preferencesStore = State(initialValue: preferencesStore)
        _updateStore = State(initialValue: updateStore)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(volumeStore)
                .environment(networkStore)
                .environment(throughputStore)
                .environment(preferencesStore)
                .environment(updateStore)
        } label: {
            MenuBarLabel()
                .environment(settings)
                .environment(volumeStore)
                .environment(networkStore)
                .environment(throughputStore)
                .environment(preferencesStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(networkStore)
                .environment(preferencesStore)
                .environment(updateStore)
        }
    }
}
