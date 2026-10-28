import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Drives", systemImage: "externaldrive") {
                DrivesSettingsView()
            }
            Tab("Network Drives", systemImage: "server.rack") {
                FavoritesSettingsView()
            }
            Tab("Notifications", systemImage: "bell") {
                NotificationSettingsView()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
        .frame(width: 520)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UpdateStore.self) private var updates
    @State private var loginItemStatus = LoginItemService.status
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var updates = updates
        Form {
            Section {
                Toggle("Open PopDisk at login", isOn: launchAtLogin)
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Allow PopDisk in System Settings to finish turning this on.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings", action: LoginItemService.openSystemSettings)
                    }
                    .font(.callout)
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Toggle("Eject external drives before the Mac sleeps", isOn: $settings.ejectBeforeSleep)
            } header: {
                Text("General")
            } footer: {
                Text("Ejecting before sleep prevents damage if you unplug a drive while the Mac is asleep. Disk images are left mounted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                Toggle("Show number of drives", isOn: $settings.showDriveCount)
                Toggle("Show an arrow while external drives are transferring", isOn: $settings.showActivity)
                Toggle("Show transfer speed while external drives are transferring", isOn: $settings.showSpeed)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("PopDisk checks GitHub once a day and asks before installing. You can also check in About.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Update speed every", selection: $settings.updateInterval) {
                    ForEach(AppSettings.updateIntervals, id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Transfer Speed")
            } footer: {
                Text("Speeds are measured only while the menu is open or the menu bar shows activity, to save battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 使用者可能在系統設定裡改了登入項目，回到這頁時重新讀取
        .onAppear { loginItemStatus = LoginItemService.status }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItemStatus != .disabled },
            set: { enabled in
                do {
                    try LoginItemService.setEnabled(enabled)
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                }
                loginItemStatus = LoginItemService.status
            }
        )
    }
}
