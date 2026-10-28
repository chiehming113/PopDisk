import AppKit
import Carbon.HIToolbox

/// 全域快捷鍵（其他 App 在前景時也能觸發）。
/// 用 Carbon 的 RegisterEventHotKey：不需要輔助使用權限，也不需要第三方套件。
struct HotKey: Codable, Hashable, Sendable {
    /// 虛擬鍵碼（kVK_*）
    var keyCode: UInt32
    /// Carbon 修飾鍵（cmdKey、shiftKey、optionKey、controlKey）
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 從錄製時的按鍵事件建立；沒有 ⌘⌥⌃ 任一修飾鍵時回傳 nil（避免單一按鍵被全域攔截）
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// 例如「⌃⌥⌘E」
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// 依目前鍵盤配置把鍵碼轉成字元
    private static func keyName(for keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer in
            UCKeyTranslate(
                buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

@MainActor
final class HotKeyService {
    enum Action: UInt32, CaseIterable {
        case ejectAll = 1
        case toggleMenu = 2
    }

    var onPress: ((Action) -> Void)?

    private var registered: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// 四字元簽章 'PpDk'
    private static let signature: OSType = 0x5070_446B

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyService.signature,
                  let action = Action(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
            // Carbon 事件在主執行緒派送
            MainActor.assumeIsolated { service.onPress?(action) }
            return noErr
        }, 1, &eventType, context, &handler)
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    /// 設定（或清除）某個動作的快捷鍵；回傳是否註冊成功（可能與其他 App 衝突）
    @discardableResult
    func set(_ hotKey: HotKey?, for action: Action) -> Bool {
        if let existing = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(existing)
        }
        guard let hotKey else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: action.rawValue),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        registered[action] = ref
        return true
    }
}
