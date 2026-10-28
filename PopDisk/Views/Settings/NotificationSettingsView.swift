import SwiftUI

struct NotificationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var notificationsDenied = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("When a drive is connected", isOn: $settings.notifyOnConnect)
                Toggle("When a drive is ejected or can't be ejected", isOn: $settings.notifyOnEject)
                Toggle("When a drive is almost full", isOn: $settings.notifyLowSpace)
                Picker("Warn when free space is below", selection: $settings.lowSpaceThreshold) {
                    ForEach(AppSettings.lowSpaceThresholds, id: \.self) { percent in
                        Text("\(percent)%").tag(percent)
                    }
                }
                .disabled(!settings.notifyLowSpace)
                if notificationsDenied {
                    HStack {
                        Label("Notifications are turned off for PopDisk.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            NotificationService.shared.openSystemSettings()
                        }
                    }
                }
            } header: {
                Text("Notify Me")
            } footer: {
                Text("Eject notifications only appear when the menu is closed, for example after using a shortcut or before sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Eject all external drives") {
                    HotKeyRecorder(hotKey: $settings.ejectAllHotKey, action: .ejectAll,
                                   recordingAction: $settings.recordingHotKey,
                                   hasConflict: settings.hotKeyConflicts.contains(.ejectAll),
                                   otherHotKey: settings.toggleMenuHotKey)
                }
                .padding(.bottom, 8)
                LabeledContent("Open the PopDisk menu") {
                    HotKeyRecorder(hotKey: $settings.toggleMenuHotKey, action: .toggleMenu,
                                   recordingAction: $settings.recordingHotKey,
                                   hasConflict: settings.hotKeyConflicts.contains(.toggleMenu),
                                   otherHotKey: settings.ejectAllHotKey)
                }
                .padding(.bottom, 8)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These shortcuts work even when another app is in front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { notificationsDenied = await NotificationService.shared.isDenied() }
    }
}
