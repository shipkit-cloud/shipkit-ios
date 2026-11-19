import Foundation
@preconcurrency import UserNotifications

/// APNs environment the device token belongs to.
public enum ShipKitPushEnvironment: String, Sendable, Equatable {
    /// Development provisioning (debug builds run from Xcode).
    case sandbox
    /// TestFlight and App Store builds.
    case production

    /// `sandbox` in debug builds, `production` otherwise.
    public static var automatic: ShipKitPushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

enum PushIdentifiers {
    static let yesNoCategory = "SHIPKIT_YESNO"
    static let scaleCategory = "SHIPKIT_SCALE"
    static let textCategory = "SHIPKIT_TEXT"
    static let openCategory = "SHIPKIT_OPEN"

    static let yes = "SHIPKIT_YES"
    static let no = "SHIPKIT_NO"
    static let reply = "SHIPKIT_REPLY"
    static func scale(_ value: Int) -> String { "SHIPKIT_S\(value)" }

    static let allCategories: Set<String> = [yesNoCategory, scaleCategory, textCategory, openCategory]
}

enum PushTokenEncoding {
    /// APNs device token as lowercase hex, the format the backend expects.
    static func hex(_ token: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(token.count * 2)
        for byte in token {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum PushAuthorization {
    static func string(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }
}

// MARK: - Payload

struct PushQuestion: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case yesno, scale, choice, text
    }

    var prompt: String?
    var type: Kind?
    var choices: [String]

    var isComplete: Bool {
        guard let prompt, !prompt.isEmpty, let type else { return false }
        return type != .choice || choices.count >= 2
    }
}

/// The `shipkit` object of a campaign push, or a delivery fetched from `GET /v1/push/deliveries/:id`.
struct PushPayload: Equatable, Sendable {
    enum Kind: String, Sendable {
        case message, feedback, question
    }

    var deliveryID: String?
    var campaignID: String?
    var kind: Kind?
    var title: String?
    var body: String?
    var question: PushQuestion?
    var feedbackPrompt: String?
    var url: String?
    var answered = false
    /// Whether `feedbackPrompt` / `url` were present at all. They're nullable, so absence means the
    /// server trimmed them to fit the payload size limit.
    var hasFeedbackPrompt = false
    var hasURL = false

    /// `nil` when `userInfo` has no `shipkit` object.
    init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo["shipkit"] as? [String: Any] else { return nil }
        self.init(object: object)
        if let aps = userInfo["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                title = alert["title"] as? String
                body = alert["body"] as? String
            } else if let alert = aps["alert"] as? String {
                body = alert
            }
        }
    }

    init(object: [String: Any]) {
        deliveryID = (object["d"] as? String) ?? (object["id"] as? String)
        campaignID = object["c"] as? String
        kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:))
        title = object["title"] as? String
        body = object["body"] as? String
        if let question = object["question"] as? [String: Any] {
            self.question = PushQuestion(
                prompt: question["prompt"] as? String,
                type: (question["type"] as? String).flatMap(PushQuestion.Kind.init(rawValue:)),
                choices: (question["choices"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
        }
        hasFeedbackPrompt = object.keys.contains("feedbackPrompt")
        feedbackPrompt = Self.nonEmpty(object["feedbackPrompt"] as? String)
        hasURL = object.keys.contains("url")
        url = Self.nonEmpty(object["url"] as? String)
        answered = object["answered"] as? Bool ?? false
    }

    init(deliveryResponse data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delivery = root["delivery"] as? [String: Any] else {
            throw ShipKitError.invalidResponse
        }
        self.init(object: delivery)
    }

    /// True when something needed to act on the push is missing and should be fetched.
    var needsFetch: Bool {
        guard deliveryID != nil else { return false }
        switch kind {
        case nil: return true
        case .question?: return !(question?.isComplete ?? false)
        case .message?: return !hasURL
        case .feedback?: return !hasFeedbackPrompt
        }
    }

    /// Fills in what the fetched delivery knows, keeping the alert text from the push.
    func merged(with fetched: PushPayload) -> PushPayload {
        var result = fetched
        result.deliveryID = fetched.deliveryID ?? deliveryID
        result.campaignID = fetched.campaignID ?? campaignID
        result.kind = fetched.kind ?? kind
        result.title = title ?? fetched.title
        result.body = body ?? fetched.body
        if fetched.question?.isComplete != true {
            result.question = question?.isComplete == true ? question : (fetched.question ?? question)
        }
        if !fetched.hasFeedbackPrompt { result.feedbackPrompt = feedbackPrompt; result.hasFeedbackPrompt = hasFeedbackPrompt }
        if !fetched.hasURL { result.url = url; result.hasURL = hasURL }
        return result
    }

    /// Text shown as the question when the prompt itself is missing.
    var displayPrompt: String {
        question?.prompt.flatMap(Self.nonEmpty) ?? body ?? title ?? ""
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// MARK: - Answers

struct PushAnswer: Equatable, Sendable {
    var value: ShipKitValue?
    var text: String?

    /// Maps a notification action to the answer it stands for. `nil` for actions that aren't answers.
    static func fromAction(_ identifier: String, userText: String?) -> PushAnswer? {
        switch identifier {
        case PushIdentifiers.yes: return PushAnswer(value: .string("yes"))
        case PushIdentifiers.no: return PushAnswer(value: .string("no"))
        case PushIdentifiers.reply:
            guard let text = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return PushAnswer(value: nil, text: text)
        default:
            let prefix = "SHIPKIT_S"
            guard identifier.hasPrefix(prefix), let score = Int(identifier.dropFirst(prefix.count)), (1...5).contains(score) else {
                return nil
            }
            return PushAnswer(value: .int(score))
        }
    }
}

struct PushTokenBody: Encodable, Sendable {
    var token: String
    var environment: String
    var authorization: String
    var context: RequestContext
}

struct PushTokenDeleteBody: Encodable, Sendable {
    var token: String
}

struct PushAsksBody: Encodable, Sendable {
    var asks: Bool
}

struct PushAsksResponse: Decodable, Sendable {
    var asks: Bool?
    var registered: Bool?
}

struct PushOpenedBody: Encodable, Sendable {
    var action: String
}

struct PushAnswerBody: Encodable, Sendable {
    var value: ShipKitValue?
    var text: String?
    var context: RequestContext
}

struct PendingPushAnswer: Codable, Sendable, Equatable {
    var deliveryID: String
    var value: ShipKitValue?
    var text: String?
}

// MARK: - Categories

enum PushCategories {
    /// Adds ShipKit's categories to the app's own. Categories with a ShipKit identifier are
    /// replaced (so titles follow the current language), everything else is kept.
    static func merge(existing: Set<UNNotificationCategory>, shipKit: Set<UNNotificationCategory>) -> Set<UNNotificationCategory> {
        let ours = Set(shipKit.map(\.identifier))
        return existing.filter { !ours.contains($0.identifier) }.union(shipKit)
    }

    static func needsRegistration(existing: Set<UNNotificationCategory>) -> Bool {
        !PushIdentifiers.allCategories.isSubset(of: Set(existing.map(\.identifier)))
    }

    struct Titles: Sendable {
        var yes: String
        var no: String
        var reply: String
        var replySend: String
        var replyPlaceholder: String
    }

    static func make(titles: Titles) -> Set<UNNotificationCategory> {
        let options: UNNotificationCategoryOptions = [.customDismissAction]
        let yesNo = UNNotificationCategory(
            identifier: PushIdentifiers.yesNoCategory,
            actions: [
                UNNotificationAction(identifier: PushIdentifiers.yes, title: titles.yes, options: []),
                UNNotificationAction(identifier: PushIdentifiers.no, title: titles.no, options: [])
            ],
            intentIdentifiers: [],
            options: options
        )
        let scale = UNNotificationCategory(
            identifier: PushIdentifiers.scaleCategory,
            actions: (1...5).map { value in
                UNNotificationAction(identifier: PushIdentifiers.scale(value), title: scaleTitle(value), options: [])
            },
            intentIdentifiers: [],
            options: options
        )
        let text = UNNotificationCategory(
            identifier: PushIdentifiers.textCategory,
            actions: [
                UNTextInputNotificationAction(
                    identifier: PushIdentifiers.reply,
                    title: titles.reply,
                    options: [],
                    textInputButtonTitle: titles.replySend,
                    textInputPlaceholder: titles.replyPlaceholder
                )
            ],
            intentIdentifiers: [],
            options: options
        )
        let open = UNNotificationCategory(
            identifier: PushIdentifiers.openCategory,
            actions: [],
            intentIdentifiers: [],
            options: options
        )
        return [yesNo, scale, text, open]
    }

    /// "★★★☆☆" reads the same in every language and shows the position on the scale at a glance.
    static func scaleTitle(_ value: Int) -> String {
        String(repeating: "★", count: value) + String(repeating: "☆", count: 5 - value)
    }
}
