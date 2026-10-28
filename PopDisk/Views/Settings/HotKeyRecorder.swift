import AppKit
import SwiftUI

/// 按下按鈕後錄下一組快捷鍵；esc 取消、⌫ 清除
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    let action: HotKeyService.Action
    /// 正在錄製的動作（共用於所有欄位）：錄製期間 AutomationController 會暫停全域快捷鍵
    @Binding var recordingAction: HotKeyService.Action?
    var hasConflict = false
    /// 另一個動作的快捷鍵；錄到相同組合時不接受（兩個動作不能共用）
    var otherHotKey: HotKey?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                label
                    .frame(minWidth: 110)
            }
            if hotKey != nil, !isRecording {
                Button {
                    hotKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear Shortcut")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = hasConflict ? "Already used by another app" : hint {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(hasConflict ? .red : .secondary)
                    .fixedSize()
                    .offset(y: 16)
            }
        }
        .onDisappear(perform: stopRecording)
        // 開始錄另一個欄位時，這個欄位停止
        .onChange(of: recordingAction) { _, new in
            if new != action { stopRecording() }
        }
        // 切到其他 App 後 local monitor 收不到按鍵，全域快捷鍵卻還暫停著，所以直接結束錄製
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private var label: Text {
        if isRecording { return Text("Press shortcut…") }
        if let hotKey { return Text(verbatim: hotKey.displayString) }
        return Text("Record Shortcut")
    }

    private func startRecording() {
        isRecording = true
        recordingAction = action
        hint = "Include ⌘, ⌥, or ⌃. Press esc to cancel."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // esc
                stopRecording()
            case 51 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty: // ⌫
                hotKey = nil
                stopRecording()
            default:
                guard let recorded = HotKey(event: event) else { return nil }
                if recorded == otherHotKey {
                    hint = "Already used by another PopDisk shortcut"
                    return nil
                }
                hotKey = recorded
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        // 切換分頁、關視窗都會呼叫；沒在錄製時不要動到共用狀態（否則會白白重新註冊）
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hint = nil
        if recordingAction == action { recordingAction = nil }
    }
}
