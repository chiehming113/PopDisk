import SwiftUI

/// 連線方式與速度，例如「USB 10 Gb/s」；受限時加上橘色提示
struct LinkLabel: View {
    let link: LinkInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(link.summary, systemImage: link.symbolName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let message = link.limitationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .labelStyle(CompactLabelStyle())
    }
}

/// 圖示與文字間距較小、圖示對齊第一行
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
                .frame(width: 14)
            configuration.title
        }
    }
}
