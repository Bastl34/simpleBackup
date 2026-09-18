import Foundation
import Security

struct BackupEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var source: String
    var destination: String
    var savePassword = false

    var title: String { name.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : name }

    /// e.g. "Documents_2026-09-18.7z", from n = 2 on "Documents_2026-09-18-2.7z"
    func archiveName(_ n: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            + "_" + formatter.string(from: .now)
        return n == 1 ? "\(base).7z" : "\(base)-\(n).7z"
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var entries: [BackupEntry] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "entries") }
    }
    @Published var sevenZip: String {
        didSet { UserDefaults.standard.set(sevenZip, forKey: "sevenZip") }
    }

    private init() {
        let defaults = UserDefaults.standard
        entries = defaults.data(forKey: "entries").flatMap { try? JSONDecoder().decode([BackupEntry].self, from: $0) } ?? []
        sevenZip = defaults.string(forKey: "sevenZip")
            ?? ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/7zz"
    }
}

/// Passwords live in the Keychain (service "simpleBackup", account = entry ID).
enum Keychain {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "simpleBackup",
         kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for id: UUID) -> Bool {
        var query = query(id)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ password: String, for entry: BackupEntry) -> Bool {
        deletePassword(for: entry.id)
        var query = query(entry.id)
        query[kSecAttrLabel as String] = "simpleBackup – \(entry.title)"
        query[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
