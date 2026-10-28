import AppKit
import SwiftUI

/// 退出失敗時顯示：誰在使用磁碟，以及重試／強制退出
struct BusyAppsView: View {
    let state: EjectState
    let onTerminate: (BusyProcess) -> Void
    let onRetry: () -> Void
    let onForceEject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .busy(let processes) where !processes.isEmpty:
                Label("In use by:", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(processes) { process in
                    BusyProcessRow(process: process) { onTerminate(process) }
                }
            case .busy:
                Label("The disk is in use, but the app using it couldn't be identified.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ejecting:
                EmptyView()
            }

            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                Button("Force Eject…", role: .destructive, action: onForceEject)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct BusyProcessRow: View {
    let process: BusyProcess
    let onTerminate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            icon
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(process.isApp ? (process.ownerApp?.name ?? process.name) : process.name)
                    .lineLimit(1)
                if !process.isApp, let owner = process.ownerApp {
                    Text("in \(owner.name)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // 三元運算式會推斷成 String 而不被翻譯，要明確指定 LocalizedStringKey
            Button(process.isApp ? LocalizedStringKey("Quit") : "End Process", action: onTerminate)
                .controlSize(.small)
                .help(process.isApp ? LocalizedStringKey("Quit the app, then try ejecting again") : "End the process, then try ejecting again")
        }
    }

    private var icon: Image {
        if let path = process.ownerApp?.bundlePath {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        }
        return Image(systemName: "terminal")
    }
}
