import ServiceManagement
import SwiftUI

/// `@State` is a macro in the current SDK, and its plugin only ships with Xcode. The alias uses the plain
/// property wrapper instead, so the app also builds with just the Command Line Tools.
typealias Local = SwiftUI.State

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @Local private var selection: UUID?
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(settings.entries) { entry in
                            Label(entry.title, systemImage: "folder").tag(entry.id)
                        }
                        .onMove { settings.entries.move(fromOffsets: $0, toOffset: $1) }
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Button(action: add) { Image(systemName: "plus").frame(width: 20, height: 20) }
                            .help("Add folder")
                        Button(action: remove) { Image(systemName: "minus").frame(width: 20, height: 20) }
                            .help("Remove entry")
                            .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 200)

                Divider()

                if let id = selection, settings.entries.contains(where: { $0.id == id }) {
                    EntryForm(entry: binding(for: id)).id(id)
                } else {
                    Text("Add a folder with +.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Spacer(minLength: 24)
                Text(verbatim: "7zz:")
                TextField("Path to 7zz", text: $settings.sevenZip)
                let found = FileManager.default.isExecutableFile(atPath: settings.sevenZip)
                Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(found ? .green : .red)
                    .help(found ? Text("7zz found") : Text("7zz not found – brew install sevenzip"))
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 590)
        .onAppear {
            selection = selection ?? settings.entries.first?.id
            launchAtLogin = SMAppService.mainApp.status == .enabled // may have been changed in System Settings
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func binding(for id: UUID) -> Binding<BackupEntry> {
        Binding {
            settings.entries.first { $0.id == id } ?? BackupEntry(id: id, name: "", source: "", destination: "")
        } set: { entry in
            if let index = settings.entries.firstIndex(where: { $0.id == id }) { settings.entries[index] = entry }
        }
    }

    private func add() {
        guard let url = pickFolder(message: String(localized: "Which folder should be backed up?")) else { return }
        let entry = BackupEntry(name: url.lastPathComponent, source: url.path,
                                destination: settings.entries.last?.destination ?? "")
        settings.entries.append(entry)
        selection = entry.id
    }

    private func remove() {
        guard let id = selection else { return }
        Keychain.deletePassword(for: id)
        settings.entries.removeAll { $0.id == id }
        selection = settings.entries.first?.id
    }
}

private struct EntryForm: View {
    @Binding var entry: BackupEntry
    @Local private var password = ""
    @Local private var confirmation = ""
    @Local private var hasPassword = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $entry.name)
                FolderRow(title: "Folder", message: String(localized: "Which folder should be backed up?"), path: $entry.source)
                FolderRow(title: "Back up to", message: String(localized: "Where should the backups go?"), path: $entry.destination)
                LabeledContent("File name", value: entry.archiveName())
            }
            Section {
                Picker("Reminder", selection: $entry.remindAfterDays) {
                    Text("Off").tag(Int?.none)
                    Text("After 1 day").tag(Int?.some(1))
                    Text("After 3 days").tag(Int?.some(3))
                    Text("After 1 week").tag(Int?.some(7))
                    Text("After 2 weeks").tag(Int?.some(14))
                    Text("After 1 month").tag(Int?.some(30))
                }
                LabeledContent("Last backup") {
                    if let last = entry.lastBackup {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never")
                    }
                }
            } footer: {
                Text("When a backup is due, the menu bar icon turns orange.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Save password in Keychain", isOn: $entry.savePassword)
                if entry.savePassword {
                    SecureField("Password", text: $password)
                    SecureField("Repeat", text: $confirmation)
                    HStack {
                        if hasPassword {
                            Label("Saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                        Spacer()
                        Button(action: save) { hasPassword ? Text("Replace") : Text("Save") }
                            .disabled(password.isEmpty || password != confirmation)
                    }
                }
            } footer: {
                Group {
                    entry.savePassword ? Text("Without a saved password, you'll be asked when the backup starts.")
                                       : Text("You'll be asked for the password on every backup.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasPassword = Keychain.hasPassword(for: entry.id) }
        .onChange(of: entry.savePassword) { _, save in
            if !save {
                Keychain.deletePassword(for: entry.id)
                hasPassword = false
            }
        }
        .onChange(of: entry.source) { old, new in
            // keep the name in sync as long as it still matches the folder name
            if entry.name.isEmpty || entry.name == URL(fileURLWithPath: old).lastPathComponent {
                entry.name = URL(fileURLWithPath: new).lastPathComponent
            }
        }
    }

    private func save() {
        hasPassword = Keychain.save(password, for: entry)
        password = ""
        confirmation = ""
    }
}

private struct FolderRow: View {
    let title: LocalizedStringKey
    let message: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Group {
                    path.isEmpty ? Text("Not selected") : Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                Button("Choose…") {
                    if let url = pickFolder(message: message, at: path) { path = url.path }
                }
            }
        }
    }
}

@MainActor
private func pickFolder(message: String, at path: String = "") -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
    return panel.runModal() == .OK ? panel.url : nil
}
