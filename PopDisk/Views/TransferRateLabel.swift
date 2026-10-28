import SwiftUI

/// 外接碟顯示「讀取／寫入」，網路碟顯示「下載／上傳」
struct TransferRateLabel: View {
    enum Style {
        case disk
        case network
    }

    let rate: TransferRate
    let style: Style

    var body: some View {
        HStack(spacing: 8) {
            part(symbol: "arrow.down", value: rate.inbound)
            part(symbol: "arrow.up", value: rate.outbound)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(rate.isActive ? .primary : .secondary)
        .help(style == .disk
              ? LocalizedStringKey("Read and write speed")
              : "Download and upload speed of the whole network connection, including other apps")
    }

    private func part(symbol: String, value: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(value >= TransferRate.displayThreshold ? TransferRate.format(value) : "—")
        }
    }
}
