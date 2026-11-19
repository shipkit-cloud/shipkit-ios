import Foundation

/// A JSON value as delivered by the ShipKit backend for settings, flags and user attributes.
public enum ShipKitValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ShipKitValue])
    case object([String: ShipKitValue])

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < Double(Int.max): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ShipKitValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: ShipKitValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> ShipKitValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> ShipKitValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Foundation representation (`NSNull`, `Bool`, `Int`, `Double`, `String`, `[Any]`, `[String: Any]`).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    /// Converts property-list or JSONSerialization output into a value.
    public init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.compactMap(ShipKitValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.compactMapValues(ShipKitValue.init(any:)))
        case let date as Date:
            self = .string(ISO8601.string(from: date))
        default:
            return nil
        }
    }

    /// Decodes the value into any `Decodable` type, returning `nil` when the shapes don't match.
    public func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        switch type {
        case is ShipKitValue.Type: return self as? T
        case is Bool.Type: return boolValue as? T
        case is Int.Type: return intValue as? T
        case is Double.Type: return doubleValue as? T
        case is Float.Type: return doubleValue.map(Float.init) as? T
        case is String.Type: return stringValue as? T
        default: break
        }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSON.decoder.decode(T.self, from: data)
    }

    /// Wraps any `Encodable` value.
    public static func encoding<T: Encodable>(_ value: T) -> ShipKitValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(ShipKitValue.self, from: data)
    }

    /// Parses JSON text. Bare words that are not valid JSON are treated as strings.
    public static func parse(_ text: String) -> ShipKitValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONDecoder().decode(ShipKitValue.self, from: data) {
            return value
        }
        return .string(text)
    }

    /// Compact JSON text, suitable for display.
    public var jsonText: String {
        switch self {
        case .string(let value): return value
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

extension ShipKitValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ShipKitValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ShipKitValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension ShipKitValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ShipKitValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ShipKitValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension ShipKitValue: CustomStringConvertible {
    public var description: String { jsonText }
}
