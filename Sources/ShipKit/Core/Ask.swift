import Foundation

/// A question or feedback request from the developer, waiting in the snapshot until your app
/// presents it with `ShipKit.presentPendingAsk()` or `.shipKitAsk()`. ShipKit never shows it by itself.
public struct ShipKitAsk: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// One question: yes/no, 1–5 stars, a choice or free text.
        case question
        /// The feedback form, with the developer's prompt above it.
        case feedback
    }

    public enum QuestionType: String, Codable, Sendable {
        case yesNo = "yesno"
        case scale
        case choice
        case text
    }

    struct Question: Codable, Sendable, Equatable {
        var prompt: String
        var type: QuestionType
        var choices: [String]
    }

    public let id: String
    public let kind: Kind
    /// Invite title and text written in the dashboard. `nil` means ShipKit's own wording.
    let title: String?
    let body: String?
    let question: Question?
    let feedbackPrompt: String?
    /// When the ask stops being offered, so a cached ask expires offline too.
    let endsAt: Date?
    /// A test sent from the dashboard: not remembered as seen, so the next test shows again.
    let isTest: Bool

    /// The question, or the line shown above the feedback form.
    public var prompt: String {
        question?.prompt ?? feedbackPrompt ?? ""
    }

    /// For previews and tests with `ShipKit.configureForTesting(snapshot:)`.
    public init(id: String, question prompt: String, type: QuestionType, choices: [String] = [], title: String? = nil, message: String? = nil) {
        self.init(id: id, kind: .question, title: title, body: message, question: Question(prompt: prompt, type: type, choices: choices), feedbackPrompt: nil, endsAt: nil, isTest: false)
    }

    /// For previews and tests with `ShipKit.configureForTesting(snapshot:)`.
    public init(id: String, feedbackPrompt: String?, title: String? = nil, message: String? = nil) {
        self.init(id: id, kind: .feedback, title: title, body: message, question: nil, feedbackPrompt: feedbackPrompt, endsAt: nil, isTest: false)
    }

    init(id: String, kind: Kind, title: String?, body: String?, question: Question?, feedbackPrompt: String?, endsAt: Date?, isTest: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.question = question
        self.feedbackPrompt = feedbackPrompt
        self.endsAt = endsAt
        self.isTest = isTest
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, question, feedbackPrompt, endsAt
        case isTest = "test"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // An unknown kind from a newer backend fails here, so the snapshot drops the ask instead of showing something broken.
        kind = try container.decode(Kind.self, forKey: .kind)
        title = Self.nonEmpty(container.decodeLossy(String.self, forKey: .title))
        body = Self.nonEmpty(container.decodeLossy(String.self, forKey: .body))
        question = container.decodeLossy(Question.self, forKey: .question)
        feedbackPrompt = Self.nonEmpty(container.decodeLossy(String.self, forKey: .feedbackPrompt))
        endsAt = container.decodeLossy(String.self, forKey: .endsAt).flatMap(ISO8601.date(from:))
        isTest = container.decodeLossy(Bool.self, forKey: .isTest) ?? false
        if kind == .question {
            guard let question, !question.prompt.isEmpty, question.type != .choice || question.choices.count >= 2 else {
                throw DecodingError.dataCorruptedError(forKey: .question, in: container, debugDescription: "Incomplete question")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(question, forKey: .question)
        try container.encodeIfPresent(feedbackPrompt, forKey: .feedbackPrompt)
        try container.encodeIfPresent(endsAt.map(ISO8601.string(from:)), forKey: .endsAt)
        if isTest { try container.encode(true, forKey: .isTest) }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// How a presented ask ended.
public enum ShipKitAskResult: Sendable, Equatable {
    /// Nothing was pending, or it couldn't be shown right now (another sheet was up, the app is
    /// blocked by a version rule, or the user turned off questions from the developer).
    case notShown
    /// The user chose "Not now" or closed the sheet without answering.
    case dismissed
    /// The user answered the question or sent feedback.
    case answered

    /// `true` when the sheet was on screen.
    public var wasShown: Bool { self != .notShown }
}

// MARK: - Wire

/// What the SDK reports about an ask. Kept in an outbox until the server has it.
struct AskEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case shown, dismissed, answered }

    var askID: String
    var kind: Kind
    var at: Date
    var test: Bool
    var appVersion: String?
    var value: ShipKitValue?
    var text: String?
}

struct AskEventBody: Encodable, Sendable {
    var event: String
    var at: String
    var test: Bool
    var appVersion: String?
}

struct AskAnswerBody: Encodable, Sendable {
    var value: ShipKitValue?
    var text: String?
    var at: String
    var test: Bool
    var context: RequestContext
}
