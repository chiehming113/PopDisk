import SwiftUI

/// 已連線的網路硬碟
struct NetworkVolumeRowView: View {
    let volume: NetworkVolume
    let preference: VolumePreference?
    let ejectState: EjectState
    let link: LinkInfo?
    let rate: TransferRate?
    let isSelected: Bool
    let actions: RowActions
    let onEject: () -> Void
    let onTerminate: (BusyProcess) -> Void
    let onForceEject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preference?.symbolName ?? "server.rack")
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

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(preference?.nickname ?? volume.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if let addFavorite = actions.addFavorite {
                            Button(action: addFavorite) {
                                Image(systemName: "star")
                            }
                            .buttonStyle(.borderless)
                            .help("Add to Saved Servers")
                        }
                    }
                    if let usedFraction = volume.usedFraction {
                        CapacityBar(usedFraction: usedFraction)
                    }
                    if let capacity {
                        Text(capacity)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(serverDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let link {
                        LinkLabel(link: link)
                    }
                    // 有網卡就能量速度，這一行一直留著，避免高度跟著流量跳動
                    if link?.interfaceName != nil {
                        TransferRateLabel(rate: rate ?? .zero, style: .network)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { QuickActions.openInFinder(volume.mountURL) }
                .help("Click to open in Finder")

                Spacer(minLength: 0)

                RowTrailingControls(
                    isEjecting: ejectState == .ejecting,
                    ejectHelp: "Disconnect",
                    onEject: onEject,
                    actions: actions
                )
            }

            if actions.isExpanded {
                InfoGrid(rows: infoRows)
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

    private var capacity: String? {
        guard let total = volume.totalBytes, let available = volume.availableBytes else { return nil }
        return Int64.capacityDescription(available: available, total: total)
    }

    /// 例如「SMB · nas.local」
    private var serverDescription: String {
        [volume.networkProtocol.displayName, volume.displayHost]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var infoRows: [(LocalizedStringKey, String)] {
        var rows: [(LocalizedStringKey, String)] = [("Protocol", volume.networkProtocol.displayName)]
        if let server = volume.serverURL { rows.append(("Server", server.absoluteString)) }
        rows.append(("Location", volume.mountURL.path))
        if let total = volume.totalBytes, let available = volume.availableBytes {
            rows.append(("Capacity", Int64.capacityDescription(available: available, total: total, compact: false)))
        }
        if let link {
            rows.append(("Connection", link.summary))
            if let name = link.interfaceName { rows.append(("Network Interface", name)) }
        }
        return rows
    }
}

/// 還沒連上的常用網路硬碟
struct NetworkFavoriteRowView: View {
    let favorite: NetworkFavorite
    let isConnecting: Bool
    let error: String?
    let onConnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "star.fill")
                .font(.body)
                .foregroundStyle(.yellow)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                    .lineLimit(1)
                Text(favorite.connectURL.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            if isConnecting {
                ProgressView().controlSize(.small)
            } else {
                Button("Connect", action: onConnect)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
