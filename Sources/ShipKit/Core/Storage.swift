import Foundation
import Security

// UserDefaults is documented as thread-safe but isn't annotated Sendable.
struct Preferences: @unchecked Sendable {
    let defaults: UserDefaults

    enum Key: String {
        case installID = "ShipKit.installID"
        case reminderState = "ShipKit.reminderState"
        case identity = "ShipKit.identity"
        case overrides = "ShipKit.overrides"
        case lastPingDay = "ShipKit.lastPingDay"
        case pushToken = "ShipKit.pushToken"
        case pushAsks = "ShipKit.pushAsks"
        case pushPendingAnswers = "ShipKit.pushPendingAnswers"
    }

    func data(_ key: Key) -> Data? { defaults.data(forKey: key.rawValue) }
    func string(_ key: Key) -> String? { defaults.string(forKey: key.rawValue) }
    func set(_ value: Any?, for key: Key) { defaults.set(value, forKey: key.rawValue) }

    func decode<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        data(key).flatMap { try? JSON.decoder.decode(T.self, from: $0) }
    }

    func encode<T: Encodable>(_ value: T, _ key: Key) {
        set(try? JSON.encoder.encode(value), for: key)
    }
}

enum InstallID {
    private static let service = "dev.shipkit.install-id"
    private static let account = "stable-id"

    /// Returns the install UUID, creating it on first use. Kept in the Keychain so it survives reinstalls.
    static func resolve(preferences: Preferences, useKeychain: Bool = true) -> String {
        if useKeychain, let existing = readKeychain() {
            preferences.set(existing, for: .installID)
            return existing
        }
        if let stored = preferences.string(.installID), UUID(uuidString: stored) != nil {
            if useKeychain { writeKeychain(stored) }
            return stored.lowercased()
        }
        let fresh = UUID().uuidString.lowercased()
        preferences.set(fresh, for: .installID)
        if useKeychain { writeKeychain(fresh) }
        return fresh
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              UUID(uuidString: string) != nil else { return nil }
        return string.lowercased()
    }

    private static func writeKeychain(_ value: String) {
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

struct SnapshotMeta: Codable, Equatable, Sendable {
    var etag: String?
    var fetchedAt: Date
    var appVersion: String
    var build: String?
}

/// Persists the last verified snapshot body and its metadata under Application Support/ShipKit/.
struct SnapshotStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ShipKit", isDirectory: true)
    }

    private var bodyURL: URL { directory.appendingPathComponent("snapshot.json") }
    private var metaURL: URL { directory.appendingPathComponent("snapshot-meta.json") }

    func load() -> (snapshot: ShipKitSnapshot, meta: SnapshotMeta)? {
        guard let body = try? Data(contentsOf: bodyURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSON.decoder.decode(SnapshotMeta.self, from: metaData),
              let snapshot = try? ShipKitSnapshot(jsonData: body) else { return nil }
        return (snapshot, meta)
    }

    func save(body: Data, meta: SnapshotMeta) {
        do {
            try ensureDirectory()
            try body.write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try JSON.encoder.encode(meta).write(to: metaURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            ShipKitLog.error("Could not write snapshot cache: \(error.localizedDescription)")
        }
    }

    func updateMeta(_ meta: SnapshotMeta) {
        try? ensureDirectory()
        try? JSON.encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: bodyURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

enum ShipKitLog {
    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ShipKit] \(message())")
        #endif
    }
}
