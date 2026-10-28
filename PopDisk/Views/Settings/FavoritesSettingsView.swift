import SwiftUI

struct FavoritesSettingsView: View {
    @Environment(NetworkStore.self) private var store
    @State private var selection: NetworkFavorite.ID?
    /// nil 代表沒有在編輯；id 不在清單內代表新增
    @State private var editing: NetworkFavorite?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if store.favorites.isEmpty {
                    Text("No saved servers yet. Add a server address such as smb://my-nas.local/Photos.")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $selection) {
                        ForEach(store.favorites) { favorite in
                            favoriteRow(favorite)
                                .tag(favorite.id)
                                .contextMenu {
                                    Button("Edit…") { editing = favorite }
                                    Button("Delete", role: .destructive) { store.delete(favorite) }
                                }
                        }
                        .onMove { store.moveFavorites(from: $0, to: $1) }
                    }
                    .frame(minHeight: 160)
                }
                HStack(spacing: 8) {
                    Button {
                        editing = NetworkFavorite(name: "", url: URL(string: "smb://")!)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add")
                    Button {
                        if let favorite = selectedFavorite { store.delete(favorite) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Delete")
                    .disabled(selectedFavorite == nil)
                    Button("Edit…") { editing = selectedFavorite }
                        .disabled(selectedFavorite == nil)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Saved Servers")
            } footer: {
                Text("Passwords are stored securely in your login keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reconnect automatically after sleep or network interruptions", isOn: $store.reconnectAutomatically)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { favorite in
            FavoriteEditorView(
                favorite: favorite,
                isNew: !store.favorites.contains { $0.id == favorite.id },
                hasSavedPassword: store.hasSavedPassword(for: favorite)
            ) { updated, password in
                store.save(updated, password: password)
            }
        }
    }

    private var selectedFavorite: NetworkFavorite? {
        store.favorites.first { $0.id == selection }
    }

    private func favoriteRow(_ favorite: NetworkFavorite) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                Text(favorite.connectURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if favorite.mountAtLaunch {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                    .help("Connects when PopDisk starts")
            }
        }
        .onTapGesture(count: 2) { editing = favorite }
    }
}

struct FavoriteEditorView: View {
    let isNew: Bool
    let hasSavedPassword: Bool
    let onSave: (NetworkFavorite, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var favorite: NetworkFavorite
    @State private var name: String
    @State private var address: String
    @State private var username: String
    @State private var password = ""

    init(favorite: NetworkFavorite, isNew: Bool, hasSavedPassword: Bool,
         onSave: @escaping (NetworkFavorite, String?) -> Void) {
        self.isNew = isNew
        self.hasSavedPassword = hasSavedPassword
        self.onSave = onSave
        _favorite = State(initialValue: favorite)
        _name = State(initialValue: favorite.name)
        _address = State(initialValue: isNew ? "" : favorite.url.absoluteString)
        _username = State(initialValue: favorite.username ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? LocalizedStringKey("Add Network Drive") : "Edit Network Drive")
                .font(.headline)

            Form {
                TextField("Address", text: $address, prompt: Text(verbatim: "smb://my-nas.local/Photos"))
                TextField("Name", text: $name, prompt: Text(suggestedName ?? ""))
                TextField("Username", text: $username, prompt: Text("Optional"))
                SecureField("Password", text: $password,
                            prompt: Text(hasSavedPassword ? LocalizedStringKey("Saved in keychain") : "Optional"))
                Toggle("Connect when PopDisk starts", isOn: $favorite.mountAtLaunch)
            }

            Group {
                if let addressError {
                    Label(addressError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Supported: smb://, nfs://, and http(s):// (WebDAV). If no password is saved, macOS will ask when connecting.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// 解析使用者輸入的位址；位址裡若帶了使用者名稱，拆出來放到使用者欄位
    private var parsedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: trimmed),
              NetworkProtocol(scheme: components.scheme) != nil,
              let host = components.host, !host.isEmpty else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    private var addressError: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, parsedURL == nil else { return nil }
        return String(localized: "Enter a full address, for example smb://my-nas.local/Photos.")
    }

    private var suggestedName: String? {
        guard let url = parsedURL else { return nil }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? url.host(percentEncoded: false) : last
    }

    private func save() {
        guard let url = parsedURL else { return }
        var updated = favorite
        updated.url = url
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmedName.isEmpty ? (suggestedName ?? url.absoluteString) : trimmedName
        let typedUser = username.trimmingCharacters(in: .whitespaces)
        let userInAddress = URLComponents(string: address.trimmingCharacters(in: .whitespaces))?.user
        updated.username = typedUser.isEmpty ? userInAddress : typedUser
        onSave(updated, password.isEmpty ? nil : password)
        dismiss()
    }
}
