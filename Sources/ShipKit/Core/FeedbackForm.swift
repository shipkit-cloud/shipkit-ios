import Foundation

/// The feedback form designed in the dashboard, as served in the snapshot (every text already in
/// the user's language). `ShipKit.FeedbackView` renders it; without one it shows the standard form.
public struct FeedbackForm: Codable, Sendable, Equatable {
    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        enum CodingKeys: String, CodingKey { case id, label }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = container.decodeLossy(String.self, forKey: .label) ?? id
        }
    }

    public struct Field: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case category, rating, longText, text, choice, email, screenshots
            /// A field type added in a later version of ShipKit. Never shown and never required.
            case unknown(String)

            init(raw: String) {
                switch raw {
                case "category": self = .category
                case "rating": self = .rating
                case "longtext": self = .longText
                case "text": self = .text
                case "choice": self = .choice
                case "email": self = .email
                case "screenshots": self = .screenshots
                default: self = .unknown(raw)
                }
            }

            var raw: String {
                switch self {
                case .category: return "category"
                case .rating: return "rating"
                case .longText: return "longtext"
                case .text: return "text"
                case .choice: return "choice"
                case .email: return "email"
                case .screenshots: return "screenshots"
                case .unknown(let raw): return raw
                }
            }
        }

        public var id: String
        public var kind: Kind
        /// `nil` on a built-in field means ShipKit's own translated label.
        public var label: String?
        public var placeholder: String?
        public var help: String?
        public var required: Bool
        public var maxLength: Int?
        /// Screenshots: how many images can be attached.
        public var max: Int?
        /// Email: the address is also used to send status updates.
        public var updates: Bool
        public var options: [Option]

        public init(
            id: String,
            kind: Kind,
            label: String? = nil,
            placeholder: String? = nil,
            help: String? = nil,
            required: Bool = false,
            maxLength: Int? = nil,
            max: Int? = nil,
            updates: Bool = false,
            options: [Option] = []
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.placeholder = placeholder
            self.help = help
            self.required = required
            self.maxLength = maxLength
            self.max = max
            self.updates = updates
            self.options = options
        }

        /// The SDK knows how to show it.
        public var isRenderable: Bool {
            if case .unknown = kind { return false }
            return kind != .choice || options.count >= 2
        }

        /// A question the developer added, as opposed to one of ShipKit's built-in fields.
        public var isCustom: Bool { id.hasPrefix("f_") }

        enum CodingKeys: String, CodingKey {
            case id, type, label, placeholder, help, required, maxLength, max, updates, options
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = Kind(raw: container.decodeLossy(String.self, forKey: .type) ?? "")
            label = container.decodeLossy(String.self, forKey: .label)
            placeholder = container.decodeLossy(String.self, forKey: .placeholder)
            help = container.decodeLossy(String.self, forKey: .help)
            required = container.decodeLossy(Bool.self, forKey: .required) ?? false
            maxLength = container.decodeLossy(Int.self, forKey: .maxLength)
            max = container.decodeLossy(Int.self, forKey: .max)
            updates = container.decodeLossy(Bool.self, forKey: .updates) ?? false
            options = container.decodeLossy(LossyArray<Option>.self, forKey: .options)?.elements ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind.raw, forKey: .type)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encodeIfPresent(help, forKey: .help)
            try container.encode(required, forKey: .required)
            try container.encodeIfPresent(maxLength, forKey: .maxLength)
            try container.encodeIfPresent(max, forKey: .max)
            if kind == .email { try container.encode(updates, forKey: .updates) }
            if !options.isEmpty { try container.encode(options, forKey: .options) }
        }
    }

    /// Changes whenever the form is edited. `nil` for the standard form.
    public var rev: String?
    /// Category used when the form has no category field.
    public var defaultCategory: FeedbackCategory
    public var fields: [Field]
    public var submitLabel: String?
    public var thanksTitle: String?
    public var thanksMessage: String?

    public init(
        rev: String? = nil,
        defaultCategory: FeedbackCategory = .bug,
        fields: [Field],
        submitLabel: String? = nil,
        thanksTitle: String? = nil,
        thanksMessage: String? = nil
    ) {
        self.rev = rev
        self.defaultCategory = defaultCategory
        self.fields = fields
        self.submitLabel = submitLabel
        self.thanksTitle = thanksTitle
        self.thanksMessage = thanksMessage
    }

    enum CodingKeys: String, CodingKey {
        case rev, defaultCategory, fields, submitLabel, thanksTitle, thanksMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rev = container.decodeLossy(String.self, forKey: .rev)
        defaultCategory = container.decodeLossy(String.self, forKey: .defaultCategory).flatMap(FeedbackCategory.init(rawValue:)) ?? .bug
        fields = container.decodeLossy(LossyArray<Field>.self, forKey: .fields)?.elements ?? []
        submitLabel = container.decodeLossy(String.self, forKey: .submitLabel)
        thanksTitle = container.decodeLossy(String.self, forKey: .thanksTitle)
        thanksMessage = container.decodeLossy(String.self, forKey: .thanksMessage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rev, forKey: .rev)
        try container.encode(defaultCategory, forKey: .defaultCategory)
        try container.encode(fields, forKey: .fields)
        try container.encodeIfPresent(submitLabel, forKey: .submitLabel)
        try container.encodeIfPresent(thanksTitle, forKey: .thanksTitle)
        try container.encodeIfPresent(thanksMessage, forKey: .thanksMessage)
    }

    /// The form designed in the dashboard. `false` for the standard form.
    public var isCustom: Bool { rev != nil }

    /// Fields the SDK shows, in order.
    public var visibleFields: [Field] { fields.filter(\.isRenderable) }

    /// The form ShipKit shows when the dashboard has none: category, optional stars, message,
    /// screenshots and an optional email, following `ShipKitConfig.Feedback`.
    public static func standard(_ config: ShipKitConfig.Feedback) -> FeedbackForm {
        var fields: [Field] = [Field(id: "category", kind: .category, required: true)]
        if config.showsRating { fields.append(Field(id: "rating", kind: .rating)) }
        fields.append(Field(id: "message", kind: .longText, required: true, maxLength: 5000))
        if config.attachScreenshot { fields.append(Field(id: "screenshots", kind: .screenshots, max: config.maxAttachments)) }
        if config.asksForEmail { fields.append(Field(id: "email", kind: .email)) }
        return FeedbackForm(fields: fields)
    }

    /// The form to show: the dashboard's when it has something to show, otherwise the standard one.
    static func resolve(_ served: FeedbackForm?, config: ShipKitConfig.Feedback) -> FeedbackForm {
        guard var form = served, !form.visibleFields.isEmpty else { return .standard(config) }
        if !config.attachScreenshot { form.fields.removeAll { $0.kind == .screenshots } }
        return form
    }

    static func isValidEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), !trimmed.contains(where: \.isWhitespace) else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return at != trimmed.startIndex && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }

    /// What the user entered so far, keyed by field id.
    struct Values: Equatable, Sendable {
        var texts: [String: String] = [:]
        var ratings: [String: Int] = [:]
        var choices: [String: String] = [:]

        func text(_ id: String) -> String {
            (texts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Visible required fields that are still empty.
    func missingRequired(_ values: Values) -> [String] {
        visibleFields.filter { field in
            guard field.required else { return false }
            switch field.kind {
            case .category, .screenshots, .unknown: return false
            case .rating: return values.ratings[field.id] == nil
            case .choice: return values.choices[field.id] == nil
            case .text, .longText, .email: return values.text(field.id).isEmpty
            }
        }.map(\.id)
    }

    /// Whether the user gave anything at all: a message, a rating or an answer.
    func hasContent(_ values: Values) -> Bool {
        visibleFields.contains { field in
            switch field.kind {
            case .rating: return values.ratings[field.id] != nil
            case .choice: return values.choices[field.id] != nil
            case .text, .longText: return !values.text(field.id).isEmpty
            case .category, .email, .screenshots, .unknown: return false
            }
        }
    }

    /// Answers to the developer's own questions. Built-in fields travel in their usual keys.
    func answers(_ values: Values) -> [FeedbackAnswer] {
        visibleFields.filter(\.isCustom).compactMap { field in
            let label = field.label ?? field.id
            switch field.kind {
            case .rating:
                return values.ratings[field.id].map { FeedbackAnswer(id: field.id, type: "rating", label: label, value: .int($0)) }
            case .choice:
                return values.choices[field.id].map { FeedbackAnswer(id: field.id, type: "choice", label: label, value: .string($0)) }
            case .text, .longText:
                let text = values.text(field.id)
                guard !text.isEmpty else { return nil }
                return FeedbackAnswer(id: field.id, type: field.kind.raw, label: label, value: .string(String(text.prefix(field.maxLength ?? 5000))))
            case .category, .email, .screenshots, .unknown:
                return nil
            }
        }
    }
}

/// One answer to a custom question, as sent with the feedback.
struct FeedbackAnswer: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var label: String
    var value: ShipKitValue
}

/// Decodes an array, skipping elements that don't decode instead of failing the whole array.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else if (try? container.decode(ShipKitValue.self)) == nil {
                // A failed decode doesn't advance the container; stop rather than loop forever.
                break
            }
        }
        elements = out
    }
}
