import SwiftUI

/// 選單列上的圖示：沒有硬碟時變淡、可顯示數量、傳輸中顯示箭頭或即時速度
struct MenuBarLabel: View {
    @Environment(VolumeStore.self) private var volumeStore
    @Environment(NetworkStore.self) private var networkStore
    @Environment(ThroughputStore.self) private var throughput
    @Environment(AppSettings.self) private var settings
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 3) {
            Image(.menuBarIcon)
                // 沒有任何硬碟時變淡，一眼就知道目前沒東西可以退出
                .opacity(driveCount == 0 ? 0.45 : 1)
            if settings.showSpeed, throughput.isTransferring {
                Text(speedText)
                    .monospacedDigit()
            } else if settings.showActivity, throughput.isTransferring {
                Image(systemName: "arrow.up.arrow.down")
            } else if settings.showDriveCount, driveCount > 1 {
                Text(driveCount.formatted())
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // 選單列一直存在，在這裡記錄看過的硬碟，選單沒打開過也會出現在設定裡
        .onChange(of: volumeStore.drives, initial: true) { recordDrives() }
        .onChange(of: networkStore.volumes, initial: true) { recordDrives() }
    }

    /// 不含已隱藏的
    private var driveCount: Int {
        preferences.visible(volumeStore.drives, key: \.preferenceKey, name: \.name).count
            + preferences.visible(networkStore.volumes, key: \.preferenceKey, name: \.name).count
    }

    private func recordDrives() {
        for drive in volumeStore.drives {
            preferences.migrate(to: drive.preferenceKey, from: drive.legacyPreferenceKeys)
            preferences.record(key: drive.preferenceKey, name: drive.volumes.first?.name ?? drive.name, kind: .external)
        }
        for volume in networkStore.volumes {
            preferences.record(key: volume.preferenceKey, name: volume.name, kind: .network)
        }
    }

    private var speedText: String {
        let total = throughput.externalTotal
        return "↓\(TransferRate.format(total.inbound)) ↑\(TransferRate.format(total.outbound))"
    }

    private var accessibilityText: String {
        let base = String(localized: "PopDisk, \(driveCount) drives")
        return throughput.isTransferring ? base + ", " + String(localized: "transferring") : base
    }
}
