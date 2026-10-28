import SwiftUI

struct DriveRowView: View {
    let drive: ExternalDrive
    let preference: VolumePreference?
    let ejectState: EjectState
    let rate: TransferRate?
    let mountingVolumeIDs: Set<Volume.ID>
    let mountErrors: [Volume.ID: String]
    let isSelected: Bool
    let actions: RowActions
    let onEject: () -> Void
    let onMount: (Volume) -> Void
    let onTerminate: (BusyProcess) -> Void
    let onForceEject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            driveRow
            if actions.isExpanded {
                DriveInfoView(drive: drive)
                    .padding(.leading, 38)
            }
            if ejectState.canRetry {
                BusyAppsView(
                    state: ejectState,
                    onTerminate: onTerminate,
                    onRetry: onEject,
                    onForceEject: onForceEject
                )
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
        .modifier(RowSelectionBackground(isSelected: isSelected))
        .contextMenu { RowActionsMenu(actions: actions) }
    }

    private var driveRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: preference?.symbolName ?? drive.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .overlay(alignment: .topTrailing) {
                    if preference?.isPinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .offset(x: 2, y: -2)
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(drive.volumes) { volume in
                    VolumeInfoView(
                        volume: volume,
                        // 只有一個卷宗時，暱稱直接取代卷宗名稱
                        title: drive.volumes.count == 1 ? (preference?.nickname ?? volume.name) : volume.name,
                        isMounting: mountingVolumeIDs.contains(volume.id),
                        mountError: mountErrors[volume.id],
                        onMount: { onMount(volume) }
                    )
                }
                if let link = drive.link {
                    LinkLabel(link: link)
                }
                // 一直佔著這一行（閒置顯示「—」），開始或停止傳輸時面板高度才不會跳動
                TransferRateLabel(rate: rate ?? .zero, style: .disk)
                if drive.volumes.count > 1 {
                    Text(preference?.nickname ?? drive.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            RowTrailingControls(
                isEjecting: ejectState == .ejecting,
                ejectHelp: "Eject",
                onEject: onEject,
                actions: actions
            )
        }
    }
}

private struct VolumeInfoView: View {
    let volume: Volume
    let title: String
    let isMounting: Bool
    let mountError: String?
    let onMount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    // 未裝載只讓名稱變灰；整列變淡的話，次要灰的副標就看不清楚
                    .foregroundStyle(volume.isMounted ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !volume.isMounted {
                    if isMounting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Mount", action: onMount)
                            .controlSize(.small)
                    }
                }
            }

            if let usedFraction = volume.usedFraction {
                CapacityBar(usedFraction: usedFraction)
            }

            // 放不下時省略檔案系統（⌘I 資訊裡還看得到），容量比較重要，不要被截斷
            ViewThatFits(in: .horizontal) {
                Text(subtitle(includingFileSystem: true))
                Text(subtitle(includingFileSystem: false))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            // 再按一次「裝載」就是重試，所以這裡只顯示原因
            if let mountError {
                Label(mountError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 點卷宗本身就在 Finder 開啟（多卷宗的裝置可以分別開）
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = volume.mountURL { QuickActions.openInFinder(url) }
        }
        .help(volume.isMounted ? Text("Click to open in Finder") : Text(verbatim: ""))
    }

    private func subtitle(includingFileSystem: Bool) -> String {
        var parts: [String] = []
        if volume.isMounted, let total = volume.totalBytes, let available = volume.availableBytes {
            parts.append(Int64.capacityDescription(available: available, total: total))
        } else if !volume.isMounted {
            parts.append(String(localized: "Not mounted"))
            if let total = volume.totalBytes {
                parts.append(total.compactByteCount)
            }
        }
        if includingFileSystem, let fileSystem = volume.fileSystemDisplayName {
            parts.append(fileSystem)
        }
        return parts.joined(separator: " · ")
    }
}

/// 進階資訊面板
private struct DriveInfoView: View {
    let drive: ExternalDrive

    var body: some View {
        InfoGrid(rows: rows)
    }

    private var rows: [(LocalizedStringKey, String)] {
        var rows: [(LocalizedStringKey, String)] = [("Device", drive.name), ("Disk", drive.id)]
        if let serial = drive.serialNumber { rows.append(("Serial Number", serial)) }
        if let link = drive.link { rows.append(("Connection", link.summary)) }
        if let reader = drive.link?.readerDetail { rows.append(("Card Reader", reader)) }
        for volume in drive.volumes {
            rows.append(("Volume", "\(volume.name) (\(volume.id))"))
            if let fileSystem = volume.fileSystemDisplayName { rows.append(("File System", fileSystem)) }
            if let total = volume.totalBytes {
                var capacity = total.formatted(.byteCount(style: .file))
                if let available = volume.availableBytes {
                    capacity = Int64.capacityDescription(available: available, total: total, compact: false)
                }
                rows.append(("Capacity", capacity))
            }
            if let url = volume.mountURL { rows.append(("Location", url.path)) }
            if let uuid = volume.uuid { rows.append(("UUID", uuid)) }
        }
        return rows
    }
}
