import SwiftUI

/// 硬碟列共用的快速動作（⋯ 選單與右鍵選單）
struct RowActions {
    var mountURL: URL?
    var isPinned: Bool
    var isExpanded: Bool
    var toggleInfo: () -> Void
    var rename: () -> Void
    var togglePin: () -> Void
    var hide: () -> Void
    /// 網路碟：加入常用（已在常用清單時為 nil）
    var addFavorite: (() -> Void)?
}

struct RowActionsMenu: View {
    let actions: RowActions

    var body: some View {
        if let url = actions.mountURL {
            Button("Open in Finder") { QuickActions.openInFinder(url) }
            Button("Show in Finder") { QuickActions.showInFinder(url) }
            Button("Open in Terminal") { QuickActions.openInTerminal(url) }
            Button("Copy Path") { QuickActions.copyPath(url) }
            Divider()
        }
        Button(actions.isExpanded ? LocalizedStringKey("Hide Info") : "Show Info", action: actions.toggleInfo)
        Button("Rename…", action: actions.rename)
        Button(actions.isPinned ? LocalizedStringKey("Unpin") : "Pin to Top", action: actions.togglePin)
        if let addFavorite = actions.addFavorite {
            Button("Add to Saved Servers", action: addFavorite)
        }
        Divider()
        Button("Hide from Menu", action: actions.hide)
    }
}

/// 列右側：退出按鈕與 ⋯ 選單
struct RowTrailingControls: View {
    let isEjecting: Bool
    let ejectHelp: LocalizedStringKey
    let onEject: () -> Void
    let actions: RowActions

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isEjecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: onEject) {
                        Image(systemName: "eject.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(ejectHelp)
                    .accessibilityLabel(ejectHelp)
                }
            }
            .frame(width: 22, height: 22)

            Menu {
                RowActionsMenu(actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }
}

/// 選取中的列加上醒目背景（鍵盤操作時看得出目前在哪一列）
struct RowSelectionBackground: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            )
    }
}

/// 資訊面板的一列：標籤 + 可選取的值
struct InfoGrid: View {
    let rows: [(LocalizedStringKey, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    Text(rows[index].0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(rows[index].1)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
