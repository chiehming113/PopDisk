import AppKit

/// 硬碟列的快速動作
@MainActor
enum QuickActions {
    static func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 開出上一層並選取卷宗，方便看到它和其他卷宗的相對位置
    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// 選單列面板裡 SwiftUI alert 不穩定，用 NSAlert 加文字欄位
    static func askForNickname(current: String?, originalName: String) -> String?? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(originalName)” in PopDisk")
        alert.informativeText = String(localized: "The nickname is only shown in PopDisk. The drive itself is not renamed. Leave empty to use the original name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = originalName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .none }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return .some(trimmed.isEmpty ? nil : trimmed)
    }
}
