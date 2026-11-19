import Foundation

public enum FeedbackCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case bug, idea, question, praise

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedbackCategory(rawValue: raw) ?? .question
    }
}

public struct FeedbackThread: Decodable, Sendable, Identifiable, Equatable {
    public enum Status: String, Decodable, Sendable {
        case new, open, waiting, resolved

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .open
        }
    }

    public let id: String
    public let category: FeedbackCategory
    public let rating: Int?
    public let status: Status
    public let preview: String
    public let createdAt: Date?
    public let updatedAt: Date?
    public let unread: Int
    public let fixedIn: String?

    enum CodingKeys: String, CodingKey {
        case id, category, rating, status, preview, createdAt, updatedAt, unread, fixedIn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = container.decodeLossy(FeedbackCategory.self, forKey: .category) ?? .question
        rating = container.decodeLossy(Int.self, forKey: .rating)
        status = container.decodeLossy(Status.self, forKey: .status) ?? .open
        preview = container.decodeLossy(String.self, forKey: .preview) ?? ""
        createdAt = container.decodeLossy(Date.self, forKey: .createdAt)
        updatedAt = container.decodeLossy(Date.self, forKey: .updatedAt)
        unread = container.decodeLossy(Int.self, forKey: .unread) ?? 0
        fixedIn = container.decodeLossy(String.self, forKey: .fixedIn)
    }
}

public struct FeedbackAttachment: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let url: String?
}

public enum Author: String, Decodable, Sendable {
    case user, developer

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Author(rawValue: raw) ?? .developer
    }
}

public struct FeedbackMessage: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let author: Author
    public let authorName: String?
    public let body: String
    public let attachments: [FeedbackAttachment]
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, author, authorName, body, attachments, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        author = container.decodeLossy(Author.self, forKey: .author) ?? .developer
        authorName = container.decodeLossy(String.self, forKey: .authorName)
        body = container.decodeLossy(String.self, forKey: .body) ?? ""
        attachments = container.decodeLossy([FeedbackAttachment].self, forKey: .attachments) ?? []
        createdAt = container.decodeLossy(Date.self, forKey: .createdAt)
    }
}

public struct FeatureRequest: Decodable, Sendable, Identifiable, Equatable {
    public enum Status: String, Decodable, Sendable, CaseIterable {
        case pending, open, planned, inProgress = "in_progress", done, rejected

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .open
        }
    }

    public let id: String
    public var title: String
    public var description: String
    public var status: Status
    public var votes: Int
    public var voted: Bool
    public var comments: Int
    public var mine: Bool
    public var linkedVersion: String?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, votes, voted, comments, mine, linkedVersion, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = container.decodeLossy(String.self, forKey: .title) ?? ""
        description = container.decodeLossy(String.self, forKey: .description) ?? ""
        status = container.decodeLossy(Status.self, forKey: .status) ?? .open
        votes = container.decodeLossy(Int.self, forKey: .votes) ?? 0
        voted = container.decodeLossy(Bool.self, forKey: .voted) ?? false
        comments = container.decodeLossy(Int.self, forKey: .comments) ?? 0
        mine = container.decodeLossy(Bool.self, forKey: .mine) ?? false
        linkedVersion = container.decodeLossy(String.self, forKey: .linkedVersion)
        createdAt = container.decodeLossy(Date.self, forKey: .createdAt)
    }
}

public struct RequestComment: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let author: Author
    public let authorName: String?
    public let body: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, author, authorName, body, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        author = container.decodeLossy(Author.self, forKey: .author) ?? .user
        authorName = container.decodeLossy(String.self, forKey: .authorName)
        body = container.decodeLossy(String.self, forKey: .body) ?? ""
        createdAt = container.decodeLossy(Date.self, forKey: .createdAt)
    }
}

// MARK: - Wire envelopes

struct ThreadsResponse: Decodable { let threads: [FeedbackThread] }
struct ThreadResponse: Decodable { let thread: FeedbackThread }
struct ThreadDetailResponse: Decodable {
    let thread: FeedbackThread
    let messages: [FeedbackMessage]
}
struct MessageResponse: Decodable { let message: FeedbackMessage }
struct UploadResponse: Decodable { let id: String }
struct ScoreResponse: Decodable { let score: Int? }
struct RequestsResponse: Decodable { let requests: [FeatureRequest] }
struct RequestResponse: Decodable { let request: FeatureRequest }
struct VoteResponse: Decodable {
    let votes: Int
    let voted: Bool
}
struct CommentsResponse: Decodable { let comments: [RequestComment] }
struct CommentResponse: Decodable { let comment: RequestComment }
struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String?
        let message: String?
    }
    let error: Body
}

struct FeedbackSubmission: Codable, Sendable {
    var category: FeedbackCategory
    var rating: Int?
    var message: String
    var email: String?
    var attachments: [String]
    var context: RequestContext

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(rating, forKey: .rating)
        try container.encode(message, forKey: .message)
        try container.encode(email, forKey: .email)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(context, forKey: .context)
    }
}

struct RatingSubmission: Encodable, Sendable {
    var subject: String
    var key: String?
    var score: Int
    var context: RequestContext
}

struct NewRequestBody: Encodable, Sendable {
    var title: String
    var description: String
    var email: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(email, forKey: .email)
    }

    enum CodingKeys: String, CodingKey { case title, description, email }
}

struct BodyText: Encodable, Sendable {
    var body: String
}

struct EventsBody: Encodable, Sendable {
    struct Ping: Encodable, Sendable {
        var appVersion: String
        var build: String
        var osVersion: String
        var platform: String = "ios"
    }
    struct Exposure: Encodable, Sendable {
        var flag: String
        var variant: String
        var count: Int
    }
    var ping: Ping?
    var exposures: [Exposure]?
}

struct IdentifyBody: Encodable, Sendable {
    var userId: String?
    var email: String?
    var name: String?
    var paymentMonthly: Double?
    var attributes: [String: ShipKitValue]?
}
