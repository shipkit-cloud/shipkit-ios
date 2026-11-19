import Foundation

/// Localized UI string, honouring `ShipKit.config.strings` overrides.
@MainActor
func L(_ key: String) -> String {
    if let override = ShipKit.config.strings[key] { return override }
    return NSLocalizedString(key, tableName: "Localizable", bundle: .module, value: key, comment: "")
}

@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: .current, arguments: arguments)
}

extension FeedbackCategory {
    @MainActor var title: String { L("category.\(rawValue)") }

    var symbol: String {
        switch self {
        case .bug: return "ladybug"
        case .idea: return "lightbulb"
        case .question: return "questionmark.bubble"
        case .praise: return "heart"
        }
    }
}

extension FeedbackThread.Status {
    @MainActor var title: String { L("thread.status.\(rawValue)") }
}

extension FeatureRequest.Status {
    @MainActor var title: String { L("request.status.\(rawValue)") }
}
