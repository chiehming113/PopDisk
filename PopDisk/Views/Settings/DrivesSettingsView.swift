import SwiftUI

/// 暱稱、圖示、排序、釘選、隱藏
struct DrivesSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section {
                if preferences.preferences.isEmpty {
                    Text("Drives you connect will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(preferences.sortedKeys, id: \.self) { key in
                            if let preference = preferences.preference(for: key) {
                                DrivePreferenceRow(key: key, preference: preference)
                            }
                        }
                        .onMove { preferences.move(from: $0, to: $1) }
                    }
                    .frame(minHeight: 220)
                }
            } header: {
                Text("Drives")
            } footer: {
                Text("Drag to change the order in the menu. Pinned drives always appear first. Nicknames and icons only change how drives look in PopDisk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DrivePreferenceRow: View {
    @Environment(PreferencesStore.self) private var preferences
    let key: String
    let preference: VolumePreference

    var body: some View {
        HStack(spacing: 8) {
            // 暱稱欄位會吃掉滑鼠拖曳（變成選取文字），給一個明顯可以拖的地方
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .help("Drag to Reorder")

            Menu {
                Button("Default Icon") {
                    preferences.update(key) { $0.symbolName = nil }
                }
                Divider()
                ForEach(PreferencesStore.symbolChoices, id: \.self) { symbol in
                    Button {
                        preferences.update(key) { $0.symbolName = symbol }
                    } label: {
                        Label(symbol, systemImage: symbol)
                            .labelStyle(.iconOnly)
                    }
                }
            } label: {
                Image(systemName: preference.symbolName ?? defaultSymbol)
                    .frame(width: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose Icon")

            VStack(alignment: .leading, spacing: 1) {
                TextField("Nickname", text: nicknameBinding, prompt: Text(preference.lastSeenName))
                    .onSubmit { preferences.setNickname(preference.nickname, for: key) }
                    .textFieldStyle(.plain)
                Text(preference.kind == .external ? LocalizedStringKey("External drive") : "Network drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            toggleButton(
                isOn: preference.isPinned,
                on: "pin.fill", off: "pin",
                help: preference.isPinned ? "Unpin" : "Pin to Top"
            ) { preferences.update(key) { $0.isPinned.toggle() } }

            toggleButton(
                isOn: preference.isHidden,
                on: "eye.slash", off: "eye",
                help: preference.isHidden ? "Show in Menu" : "Hide from Menu"
            ) { preferences.update(key) { $0.isHidden.toggle() } }

            Button {
                preferences.forget(key)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this drive's settings")
        }
        .opacity(preference.isHidden ? 0.6 : 1)
    }

    private var defaultSymbol: String {
        preference.kind == .external ? "externaldrive.fill" : "server.rack"
    }

    private var nicknameBinding: Binding<String> {
        Binding(
            get: { preference.nickname ?? "" },
            set: { newValue in preferences.update(key) { $0.nickname = newValue } }
        )
    }

    private func toggleButton(isOn: Bool, on: String, off: String, help: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? on : off)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
