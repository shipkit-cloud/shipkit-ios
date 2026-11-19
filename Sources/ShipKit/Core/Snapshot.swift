import Foundation

/// The resolved configuration for this install, as returned by `POST /v1/snapshot`.
public struct ShipKitSnapshot: Codable, Sendable, Equatable {
    public var release: Int
    public var ttl: Int?
    public var settings: [String: ShipKitValue]
    public var flags: [String: ShipKitValue]
    public var version: VersionInfo?
    public var inbox: Inbox?

    public struct Inbox: Codable, Sendable, Equatable {
        public var unread: Int

        public init(unread: Int) {
            self.unread = unread
        }
    }

    public init(
        release: Int = 0,
        ttl: Int? = nil,
        settings: [String: ShipKitValue] = [:],
        flags: [String: ShipKitValue] = [:],
        version: VersionInfo? = nil,
        unreadCount: Int = 0
    ) {
        self.release = release
        self.ttl = ttl
        self.settings = settings
        self.flags = flags
        self.version = version
        self.inbox = Inbox(unread: unreadCount)
    }

    /// Decodes a snapshot from the JSON body served by the backend.
    public init(jsonData: Data) throws {
        self = try JSON.decoder.decode(ShipKitSnapshot.self, from: jsonData)
    }

    enum CodingKeys: String, CodingKey {
        case release, ttl, settings, flags, version, inbox
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        release = container.decodeLossy(Int.self, forKey: .release) ?? 0
        ttl = container.decodeLossy(Int.self, forKey: .ttl)
        settings = container.decodeLossy([String: ShipKitValue].self, forKey: .settings) ?? [:]
        flags = container.decodeLossy([String: ShipKitValue].self, forKey: .flags) ?? [:]
        version = try container.decodeIfPresent(VersionInfo.self, forKey: .version)
        inbox = container.decodeLossy(Inbox.self, forKey: .inbox)
    }
}

/// Version policy for the running app.
public struct VersionInfo: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok, recommended, required, blocked, maintenance

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .ok
        }
    }

    public struct Reminder: Codable, Sendable, Equatable {
        public var everyLaunches: Int?
        public var everyDays: Int?
        public var maxPerVersion: Int?
        public var allowSkip: Bool?

        public init(everyLaunches: Int? = nil, everyDays: Int? = nil, maxPerVersion: Int? = nil, allowSkip: Bool? = nil) {
            self.everyLaunches = everyLaunches
            self.everyDays = everyDays
            self.maxPerVersion = maxPerVersion
            self.allowSkip = allowSkip
        }
    }

    public struct Maintenance: Codable, Sendable, Equatable {
        public var message: String?
        public var until: Date?

        public init(message: String? = nil, until: Date? = nil) {
            self.message = message
            self.until = until
        }

        enum CodingKeys: String, CodingKey { case message, until }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = container.decodeLossy(String.self, forKey: .message)
            until = container.decodeLossy(String.self, forKey: .until).flatMap(ISO8601.date(from:))
        }
    }

    public struct OSFloor: Codable, Sendable, Equatable {
        public var minOS: String?
        public var message: String?

        public init(minOS: String? = nil, message: String? = nil) {
            self.minOS = minOS
            self.message = message
        }
    }

    public struct WhatsNew: Codable, Sendable, Equatable {
        public var version: String
        public var items: [String]

        public init(version: String, items: [String]) {
            self.version = version
            self.items = items
        }
    }

    public var status: Status
    public var current: String?
    public var min: String?
    public var recommended: String?
    public var latest: String?
    public var storeURL: URL?
    public var title: String?
    public var message: String?
    public var reminder: Reminder?
    public var maintenance: Maintenance?
    public var osFloor: OSFloor?
    public var whatsNew: WhatsNew?
    public var personal: [String]

    public init(
        status: Status,
        current: String? = nil,
        min: String? = nil,
        recommended: String? = nil,
        latest: String? = nil,
        storeURL: URL? = nil,
        title: String? = nil,
        message: String? = nil,
        reminder: Reminder? = nil,
        maintenance: Maintenance? = nil,
        osFloor: OSFloor? = nil,
        whatsNew: WhatsNew? = nil,
        personal: [String] = []
    ) {
        self.status = status
        self.current = current
        self.min = min
        self.recommended = recommended
        self.latest = latest
        self.storeURL = storeURL
        self.title = title
        self.message = message
        self.reminder = reminder
        self.maintenance = maintenance
        self.osFloor = osFloor
        self.whatsNew = whatsNew
        self.personal = personal
    }

    enum CodingKeys: String, CodingKey {
        case status, current, min, recommended, latest, storeURL, title, message
        case reminder, maintenance, osFloor, whatsNew, personal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeLossy(Status.self, forKey: .status) ?? .ok
        current = container.decodeLossy(String.self, forKey: .current)
        min = container.decodeLossy(String.self, forKey: .min)
        recommended = container.decodeLossy(String.self, forKey: .recommended)
        latest = container.decodeLossy(String.self, forKey: .latest)
        storeURL = container.decodeLossy(String.self, forKey: .storeURL).flatMap(URL.init(string:))
        title = container.decodeLossy(String.self, forKey: .title)
        message = container.decodeLossy(String.self, forKey: .message)
        reminder = container.decodeLossy(Reminder.self, forKey: .reminder)
        maintenance = container.decodeLossy(Maintenance.self, forKey: .maintenance)
        osFloor = container.decodeLossy(OSFloor.self, forKey: .osFloor)
        whatsNew = container.decodeLossy(WhatsNew.self, forKey: .whatsNew)
        personal = container.decodeLossy([String].self, forKey: .personal) ?? []
    }

    /// The version a reminder points to.
    public var targetVersion: String? {
        recommended ?? latest
    }
}

/// What the app should do about its current version.
public enum VersionStatus: Sendable, Equatable {
    case ok
    case updateRecommended(VersionInfo)
    case updateRequired(VersionInfo)
    case blocked(VersionInfo)
    case maintenance(VersionInfo)

    public var info: VersionInfo? {
        switch self {
        case .ok: return nil
        case .updateRecommended(let info), .updateRequired(let info), .blocked(let info), .maintenance(let info): return info
        }
    }

    /// `true` for states that must cover the whole app.
    public var isBlocking: Bool {
        switch self {
        case .updateRequired, .blocked, .maintenance: return true
        case .ok, .updateRecommended: return false
        }
    }
}
